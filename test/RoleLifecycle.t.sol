// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";

contract RoleLifecycleTest is Test {
    OGClubStaking internal staking;
    OGClubFurniture internal furniture;
    address internal first = makeAddr("first");
    address internal later = makeAddr("later");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(1_800_000_000);
        staking = new OGClubStaking(IERC20(makeAddr("token")), makeAddr("vault"), address(this), 1e18);
        furniture = new OGClubFurniture(address(this), address(this));
    }

    function propose() internal returns (uint256 maturity) {
        staking.grantSpender(first);
        furniture.grantMinter(first);
        assertTrue(staking.spenders(first));
        staking.grantSpender(later);
        furniture.grantMinter(later);
        assertFalse(staking.spenders(later));
        assertFalse(furniture.minters(later));
        maturity = block.timestamp + 7 days;
        assertEq(staking.pendingSpenders(later), maturity);
        assertEq(furniture.pendingMinters(later), maturity);
    }

    function test_ActivationAtMaturityAndLastSecond() public {
        uint256 maturity = propose();
        vm.warp(maturity - 1);
        vm.expectRevert(abi.encodeWithSelector(OGClubStaking.SpenderDelayNotElapsed.selector, later, maturity));
        staking.activateSpender(later);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, later, maturity));
        furniture.activateMinter(later);
        vm.warp(maturity);
        vm.prank(stranger);
        staking.activateSpender(later);
        assertTrue(staking.spenders(later));
        assertEq(staking.pendingSpenders(later), 0);
        vm.warp(maturity + 7 days);
        vm.prank(stranger);
        furniture.activateMinter(later);
        assertTrue(furniture.minters(later));
    }

    function test_SpenderLastSecondActivates() public {
        uint256 maturity = propose();
        vm.warp(maturity + 7 days);
        staking.activateSpender(later);
        assertTrue(staking.spenders(later));
    }

    function testFuzz_ExpiredProposalsCannotActivateOrCancel(uint32 late) public {
        uint256 maturity = propose();
        vm.warp(maturity + 7 days + bound(late, 1, 365 days));
        vm.expectRevert(abi.encodeWithSelector(OGClubStaking.NoSpenderProposal.selector, later));
        staking.activateSpender(later);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, later));
        furniture.activateMinter(later);
        vm.expectRevert(abi.encodeWithSelector(OGClubStaking.NoSpenderProposal.selector, later));
        staking.cancelSpender(later);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NoMinterProposal.selector, later));
        furniture.cancelMinter(later);
        assertFalse(staking.spenders(later));
        assertFalse(furniture.minters(later));
        staking.grantSpender(later);
        furniture.grantMinter(later);
        assertEq(staking.pendingSpenders(later), block.timestamp + 7 days);
        assertEq(furniture.pendingMinters(later), block.timestamp + 7 days);
    }

    function test_CancelRevokeRegrantAndReproposal() public {
        uint256 maturity = propose();
        staking.cancelSpender(later);
        assertEq(staking.pendingSpenders(later), 0);
        vm.expectRevert(abi.encodeWithSelector(OGClubStaking.NoSpenderProposal.selector, later));
        staking.activateSpender(later);
        staking.revokeSpender(first);
        assertFalse(staking.spenders(first));
        staking.grantSpender(first);
        assertFalse(staking.spenders(first));
        vm.warp(maturity - 1);
        staking.grantSpender(first);
        vm.warp(maturity);
        vm.expectRevert(
            abi.encodeWithSelector(OGClubStaking.SpenderDelayNotElapsed.selector, first, maturity - 1 + 7 days)
        );
        staking.activateSpender(first);
        vm.warp(maturity - 1 + 7 days);
        staking.activateSpender(first);
        staking.grantSpender(first);
        staking.cancelSpender(first);
        assertTrue(staking.spenders(first));
        staking.grantSpender(first);
        staking.revokeSpender(first);
        assertFalse(staking.spenders(first));
        assertEq(staking.pendingSpenders(first), 0);
        assertTrue(staking.bootstrapped());
    }

    function test_OnlyOwnerProposesCancelsAndRevokes() public {
        propose();
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.grantSpender(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.cancelSpender(later);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staking.revokeSpender(first);
        vm.stopPrank();
    }

    function test_InvalidGrantDoesNotSpendBootstrapAndZeroAddressesRejected() public {
        vm.expectRevert(OGClubStaking.InvalidAddress.selector);
        staking.grantSpender(address(0));
        assertFalse(staking.bootstrapped());
        vm.expectRevert(OGClubStaking.InvalidAddress.selector);
        staking.revokeSpender(address(0));
        staking.grantSpender(first);
        assertTrue(staking.spenders(first));
    }

    function test_OwnershipHandoverDoesNotResetBootstrapAndRenunciationDoesNotBlockActivation() public {
        uint256 maturity = propose();
        staking.transferOwnership(stranger);
        assertEq(staking.owner(), address(this));
        vm.startPrank(stranger);
        staking.acceptOwnership();
        staking.grantSpender(stranger);
        assertFalse(staking.spenders(stranger));
        staking.renounceOwnership();
        vm.stopPrank();
        vm.warp(maturity);
        staking.activateSpender(later);
        assertTrue(staking.spenders(later));
        assertTrue(staking.bootstrapped());
    }
}
