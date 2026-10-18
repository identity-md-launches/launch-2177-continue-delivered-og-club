// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OGClubStaking} from "src/OGClubStaking.sol";
import {OGClubFarmVault} from "src/OGClubFarmVault.sol";
import {TestToken, NoReturnToken} from "./helpers/TokenMocks.sol";

/// @dev Deliberately mutates balances before returning false. A caller must undo
/// this mutation and any earlier successful transfer in the same operation.
contract FalseAfterTransferToken is ERC20 {
    address public rejectedRecipient;

    constructor() ERC20("Atomicity test token", "ATT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function reject(address recipient) external {
        rejectedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        return to != rejectedRecipient;
    }
}

contract TokenFailureAtomicityTest is Test {
    FalseAfterTransferToken internal token;
    OGClubFarmVault internal vault;
    OGClubStaking internal staking;
    address internal alice = makeAddr("atomicity-alice");
    address internal bob = makeAddr("atomicity-bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new FalseAfterTransferToken();
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 1e18 + 1);
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
    }

    function accountHash() internal view returns (bytes32) {
        (uint128 balance, uint48 updated, uint80 remainder, uint256 points) = staking.accounts(alice);
        return keccak256(abi.encode(balance, updated, remainder, points));
    }

    function leaf(uint256 id, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, account, amount))));
    }

    function test_SecondUnstakeTransferFailureRestoresVaultFeeAndAccrualCheckpoint() public {
        vm.prank(alice);
        staking.stake(100 ether + 1);
        vm.warp(vm.getBlockTimestamp() + 31);
        bytes32 stateBefore = accountHash();
        uint256 pointsBefore = staking.pointsOf(alice);
        uint256 liquidBefore = token.balanceOf(alice);
        token.reject(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        staking.unstake(99 ether + 1);
        assertEq(accountHash(), stateBefore, "failed exit must not checkpoint");
        assertEq(staking.pointsOf(alice), pointsBefore);
        assertEq(staking.totalStaked(), 100 ether + 1);
        assertEq(token.balanceOf(address(staking)), 100 ether + 1);
        assertEq(token.balanceOf(address(vault)), 0, "first transfer must also roll back");
        assertEq(token.balanceOf(alice), liquidBefore);

        token.reject(bob);
        vm.prank(alice);
        staking.unstake(99 ether + 1);
        assertEq(token.balanceOf(address(vault)), 0.99 ether + 1);
        assertEq(staking.stakeOf(alice), 1 ether);
        assertEq(staking.pointsOf(alice), pointsBefore);
    }

    function test_OneWeiExitDoesNotCallTheZeroNetRecipientTransfer() public {
        vm.prank(alice);
        staking.stake(1);
        token.reject(alice);
        vm.prank(alice);
        staking.unstake(1);
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(token.balanceOf(address(vault)), 1);
    }

    function test_PackedStakeOverflowRestoresTransferAndPendingPointState() public {
        uint256 maximum = type(uint128).max;
        token.mint(alice, maximum);
        vm.prank(alice);
        staking.stake(maximum);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        uint256 liquidBefore = token.balanceOf(alice);
        uint256 pointsBefore = staking.pointsOf(alice);
        bytes32 stateBefore = accountHash();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(128), maximum + 1)
        );
        staking.stake(1);
        assertEq(token.balanceOf(alice), liquidBefore);
        assertEq(token.balanceOf(address(staking)), maximum);
        assertEq(staking.totalStaked(), maximum);
        assertEq(accountHash(), stateBefore);
        assertEq(staking.pointsOf(alice), pointsBefore);
        // Failure has not stranded the already valid position.
        vm.prank(alice);
        staking.unstake(maximum);
        assertEq(staking.totalStaked(), 0);
    }

    function test_FalseReturningPayoutPreservesEarlierClaimsAndAllReservations() public {
        token.mint(address(vault), 1000 ether);
        bytes32 a = leaf(1, alice, 100 ether);
        bytes32 b = leaf(1, bob, 200 ether);
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        vault.proposeSeason(root, 300 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        vault.claim(1, alice, 100 ether, proof);
        token.reject(bob);
        proof[0] = a;
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vault.claim(1, bob, 200 ether, proof);
        assertTrue(vault.claimed(1, alice));
        assertFalse(vault.claimed(1, bob));
        assertEq(token.balanceOf(alice), 1100 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(vault)), 900 ether);
        assertEq(vault.reserved(), 200 ether);
        (bytes32 actualRoot, uint256 remaining,, bool closed) = vault.seasons(1);
        assertEq(actualRoot, root);
        assertEq(remaining, 200 ether);
        assertFalse(closed);
        token.reject(alice);
        vault.claim(1, bob, 200 ether, proof);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(bob), 200 ether);
    }

    function test_SenderSurchargeCannotConsumeAnotherSeasonsReservation() public {
        TestToken taxed = new TestToken(18);
        OGClubFarmVault other = new OGClubFarmVault(taxed, address(this));
        taxed.mint(address(other), 1000 ether);
        other.proposeSeason(leaf(1, alice, 200 ether), 200 ether);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        other.proposeSeason(leaf(2, bob, 400 ether), 400 ether);
        taxed.configureFee(1000, true);
        vm.expectRevert(OGClubFarmVault.UnexpectedTokenDebit.selector);
        other.claim(1, alice, 200 ether, new bytes32[](0));
        assertEq(taxed.balanceOf(address(other)), 1000 ether);
        assertEq(taxed.totalSupply(), 1000 ether, "surcharge burn rolled back");
        assertEq(taxed.balanceOf(alice), 0);
        assertEq(other.reserved(), 600 ether);
        assertFalse(other.claimed(1, alice));
        (, uint256 firstRemaining,,) = other.seasons(1);
        (, uint256 secondRemaining,,) = other.seasons(2);
        assertEq(firstRemaining, 200 ether);
        assertEq(secondRemaining, 400 ether);
    }

    function test_VaultAcceptsNoReturnTokensAndPaysOnlyTheProvenAccount() public {
        NoReturnToken legacy = new NoReturnToken();
        OGClubFarmVault other = new OGClubFarmVault(IERC20(address(legacy)), address(this));
        legacy.mint(address(other), 10 ether);
        other.proposeSeason(leaf(1, alice, 5 ether), 5 ether);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(bob);
        other.claim(1, alice, 5 ether, new bytes32[](0));
        assertEq(legacy.balanceOf(alice), 5 ether);
        assertEq(legacy.balanceOf(bob), 0);
        assertEq(legacy.balanceOf(address(other)), 5 ether);
        assertEq(other.reserved(), 0);
        assertTrue(other.claimed(1, alice));
    }
}
