// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {TestToken} from "./helpers/TokenMocks.sol";

contract FarmVaultTest is Test {
    TestToken internal token;
    OGClubFarmVault internal vault;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new TestToken(18);
        vault = new OGClubFarmVault(token, address(this));
        token.mint(address(vault), 1000 ether);
    }

    function leaf(uint256 season, address who, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(season, who, amount))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function proof(bytes32 sibling) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function noProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function propose(uint256 amount) internal returns (uint256 id) {
        id = vault.seasonCount() + 1;
        vault.proposeSeason(leaf(id, alice, amount), amount);
    }

    function test_DelayExactBoundaryAndPermissionlessClaimPaidToAccountOnly() public {
        uint256 id = propose(200 ether);
        (,, uint256 opensAt,) = vault.seasons(id);
        assertEq(opensAt, block.timestamp + 3 days);
        assertEq(vault.reserved(), 200 ether);
        vm.warp(opensAt - 1);
        vm.expectRevert(OGClubFarmVault.ClaimsNotOpen.selector);
        vault.claim(id, alice, 200 ether, noProof());
        vm.warp(opensAt);
        vm.prank(stranger);
        vault.claim(id, alice, 200 ether, noProof());
        assertEq(token.balanceOf(alice), 200 ether);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(vault.reserved(), 0);
        assertTrue(vault.claimed(id, alice));
        vm.expectRevert(OGClubFarmVault.AlreadyClaimed.selector);
        vault.claim(id, alice, 200 ether, noProof());
    }

    function test_HalfCapUsesOnlyUnreservedBalanceAndFloorsOddWei() public {
        token.mint(address(vault), 1);
        vm.expectRevert(OGClubFarmVault.BudgetExceeded.selector);
        vault.proposeSeason(leaf(1, alice, 500 ether + 1), 500 ether + 1);
        propose(500 ether);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(OGClubFarmVault.BudgetExceeded.selector);
        vault.proposeSeason(leaf(2, alice, 250 ether + 1), 250 ether + 1);
        propose(250 ether);
        assertEq(vault.reserved(), 750 ether);
        assertGe(token.balanceOf(address(vault)), vault.reserved());
    }

    function test_ProposalIntervalAtExactBoundaryIncludingAfterCancel() public {
        uint256 id = propose(100 ether);
        uint256 proposedAt = block.timestamp;
        vault.cancelSeason(id);
        assertEq(vault.reserved(), 0);
        vm.warp(proposedAt + 7 days - 1);
        vm.expectRevert(OGClubFarmVault.ProposalTooSoon.selector);
        vault.proposeSeason(leaf(2, alice, 100 ether), 100 ether);
        vm.warp(proposedAt + 7 days);
        propose(100 ether);
        assertEq(vault.lastProposedAt(), block.timestamp);
    }

    function test_CancelBeforeOpenOnlyReleasesReserveWithoutTransferring() public {
        uint256 id = propose(200 ether);
        (,, uint256 opensAt,) = vault.seasons(id);
        vm.warp(opensAt - 1);
        vault.cancelSeason(id);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
        vm.warp(opensAt);
        vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        vault.claim(id, alice, 200 ether, noProof());
        vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        vault.cancelSeason(id);
        vm.warp(vault.lastProposedAt() + 7 days);
        id = propose(200 ether);
        (,, opensAt,) = vault.seasons(id);
        vm.warp(opensAt);
        vm.expectRevert(OGClubFarmVault.CancellationTooLate.selector);
        vault.cancelSeason(id);
    }

    function test_ProofRejectsWrongAccountAmountSeasonAndSingleHash() public {
        bytes32 a = leaf(1, alice, 100 ether);
        bytes32 b = leaf(1, bob, 150 ether);
        vault.proposeSeason(pair(a, b), 250 ether);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(1, alice, 101 ether, proof(b));
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(1, stranger, 100 ether, proof(b));
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(1, alice, 100 ether, proof(a));
        vm.prank(stranger);
        vault.claim(1, alice, 100 ether, proof(b));
        vm.prank(stranger);
        vault.claim(1, bob, 150 ether, proof(a));
        assertEq(vault.reserved(), 0);
        vm.warp(vault.lastProposedAt() + 7 days);
        vault.proposeSeason(pair(a, b), 250 ether);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(2, alice, 100 ether, proof(b));
        vm.warp(vault.lastProposedAt() + 7 days);
        vault.proposeSeason(keccak256(abi.encode(uint256(3), alice, uint256(100 ether))), 100 ether);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(3, alice, 100 ether, noProof());
    }

    function test_TotalBudgetCapsEvenInconsistentMerkleTree() public {
        bytes32 a = leaf(1, alice, 100 ether);
        bytes32 b = leaf(1, bob, 100 ether);
        vault.proposeSeason(pair(a, b), 150 ether);
        vm.warp(block.timestamp + 3 days);
        vault.claim(1, alice, 100 ether, proof(b));
        vm.expectRevert(OGClubFarmVault.BudgetExceeded.selector);
        vault.claim(1, bob, 100 ether, proof(a));
        assertFalse(vault.claimed(1, bob));
        assertEq(vault.reserved(), 50 ether);
    }

    function test_ReleaseExactly90DaysAfterOpeningAndNeverWithdrawsTokens() public {
        uint256 id = propose(200 ether);
        (,, uint256 opensAt,) = vault.seasons(id);
        vm.warp(opensAt + 90 days - 1);
        vm.expectRevert(OGClubFarmVault.ReleaseTooEarly.selector);
        vault.releaseSeason(id);
        vm.warp(opensAt + 90 days);
        vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        vault.claim(id, alice, 200 ether, noProof());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.releaseSeason(id);
        vault.releaseSeason(id);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
        vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        vault.releaseSeason(id);
        propose(500 ether);
    }

    function test_ClaimLastSecondBeforeExpirationAndPartialRelease() public {
        bytes32 a = leaf(1, alice, 100 ether);
        bytes32 b = leaf(1, bob, 100 ether);
        vault.proposeSeason(pair(a, b), 200 ether);
        (,, uint256 opensAt,) = vault.seasons(1);
        vm.warp(opensAt + 90 days - 1);
        vault.claim(1, alice, 100 ether, proof(b));
        vm.warp(opensAt + 90 days);
        vault.releaseSeason(1);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(address(vault)), 900 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_OnlyOwnerCanProposeCancelAndNoSweepOrApprovalOrPause() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.proposeSeason(leaf(1, alice, 1), 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.cancelSeason(1);
        vm.stopPrank();
        (bool ok,) = address(vault).call(abi.encodeWithSignature("withdraw(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("sweep(address)", address(token)));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok);
        (ok,) =
            address(vault).call(abi.encodeWithSignature("approve(address,uint256)", address(this), type(uint256).max));
        assertFalse(ok);
        assertEq(token.balanceOf(address(vault)), 1000 ether);
    }

    function test_InvalidSeasonRootAndTotal() public {
        vm.expectRevert(OGClubFarmVault.InvalidProposal.selector);
        vault.proposeSeason(bytes32(0), 1);
        vm.expectRevert(OGClubFarmVault.InvalidProposal.selector);
        vault.proposeSeason(leaf(1, alice, 0), 0);
        vm.expectRevert(OGClubFarmVault.InvalidSeason.selector);
        vault.cancelSeason(0);
        vm.expectRevert(OGClubFarmVault.InvalidSeason.selector);
        vault.releaseSeason(1);
        vm.expectRevert(OGClubFarmVault.InvalidSeason.selector);
        vault.claim(1, alice, 1, noProof());
    }

    function test_FailedTokenTransferRestoresClaimAndReservations() public {
        uint256 id = propose(200 ether);
        vm.warp(block.timestamp + 3 days);
        token.configureFalse(true);
        vm.expectRevert();
        vault.claim(id, alice, 200 ether, noProof());
        assertFalse(vault.claimed(id, alice));
        assertEq(vault.reserved(), 200 ether);
        token.configureFalse(false);
        token.configureFee(1000, true);
        vm.expectRevert(OGClubFarmVault.UnexpectedTokenDebit.selector);
        vault.claim(id, alice, 200 ether, noProof());
        assertFalse(vault.claimed(id, alice));
        assertEq(vault.reserved(), 200 ether);
        token.configureFee(1000, false);
        vault.claim(id, alice, 200 ether, noProof());
        assertEq(token.balanceOf(alice), 180 ether);
        assertEq(vault.reserved(), 0);
    }

    function test_TokenCallbackCannotClaimTwice() public {
        uint256 id = propose(200 ether);
        vm.warp(block.timestamp + 3 days);
        token.configureCallback(address(vault), abi.encodeCall(vault.claim, (id, alice, 200 ether, noProof())));
        vault.claim(id, alice, 200 ether, noProof());
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(alice), 200 ether);
        assertEq(vault.reserved(), 0);
    }

    function test_OwnershipHandoverPreservesSeasons() public {
        uint256 id = propose(200 ether);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), address(this));
        vm.prank(bob);
        vault.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.cancelSeason(id);
        vm.warp(block.timestamp + 3 days);
        vault.claim(id, alice, 200 ether, noProof());
        assertEq(token.balanceOf(alice), 200 ether);
    }

    function testFuzz_ReserveCapAndClaimConservation(uint96 rawFunding, uint96 rawAmount) public {
        uint256 funding = bound(rawFunding, 2, 1_000_000 ether);
        token = new TestToken(18);
        vault = new OGClubFarmVault(token, address(this));
        token.mint(address(vault), funding);
        uint256 amount = bound(rawAmount, 1, funding / 2);
        vault.proposeSeason(leaf(1, alice, amount), amount);
        assertEq(vault.reserved(), amount);
        vm.warp(block.timestamp + 3 days);
        vault.claim(1, alice, amount, noProof());
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(vault)), funding - amount);
        assertEq(vault.reserved(), 0);
    }

    function test_InvalidRecipientsAndZeroAllocation() public {
        vault.proposeSeason(leaf(1, address(vault), 1), 1);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(OGClubFarmVault.InvalidAddress.selector);
        vault.claim(1, address(vault), 1, noProof());
        vm.expectRevert(OGClubFarmVault.InvalidAddress.selector);
        vault.claim(1, address(0), 1, noProof());
        vm.warp(vault.lastProposedAt() + 7 days);
        vault.proposeSeason(leaf(2, alice, 0), 1);
        vm.warp(block.timestamp + 3 days);
        vault.claim(2, alice, 0, noProof());
        assertTrue(vault.claimed(2, alice));
        assertEq(token.balanceOf(alice), 0);
        assertEq(vault.reserved(), 2);
    }

    function test_OwnerCallbackCannotReserveAgainstAnInFlightPayout() public {
        // The owner may itself be a contract called by a token hook before the payout is debited.
        // All reservation mutations must share the claim guard, not just claim itself.
        vault = new OGClubFarmVault(token, address(token));
        token.mint(address(vault), 1000 ether);
        token.execute(address(vault), abi.encodeCall(vault.proposeSeason, (leaf(1, alice, 500 ether), 500 ether)));
        vm.warp(block.timestamp + 7 days);
        token.configureCallback(
            address(vault), abi.encodeCall(vault.proposeSeason, (leaf(2, bob, 500 ether), 500 ether))
        );
        vault.claim(1, alice, 500 ether, noProof());
        assertFalse(token.callbackSucceeded());
        assertEq(vault.seasonCount(), 1);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(address(vault)), 500 ether);
        token.configureCallback(address(0), "");
        vm.expectRevert(OGClubFarmVault.BudgetExceeded.selector);
        token.execute(address(vault), abi.encodeCall(vault.proposeSeason, (leaf(2, bob, 500 ether), 500 ether)));
    }
}
