// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {TestToken, NoReturnToken} from "./helpers/TokenMocks.sol";

contract StakingTest is Test {
    TestToken internal token;
    OGClubStaking internal staking;
    address internal alice = makeAddr("alice");
    address internal vault = makeAddr("vault");
    address internal spender = makeAddr("spender");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new TestToken(18);
        staking = new OGClubStaking(token, vault, address(this), 1e18);
        staking.grantSpender(spender);
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
    }

    function stake(uint256 amount) internal {
        vm.prank(alice);
        staking.stake(amount);
    }

    function spend(uint256 amount) internal {
        vm.prank(spender);
        staking.spendPoints(alice, amount);
    }

    function test_ExactContinuousAccrualAtBoundariesAndSpend() public {
        uint256 start = block.timestamp;
        stake(2.5 ether);
        assertEq(staking.pointsOf(alice), 0);
        vm.warp(start + 1);
        assertEq(staking.pointsOf(alice), uint256(2.5 ether) / 86400);
        vm.warp(start + 1 days - 1);
        assertEq(staking.pointsOf(alice), uint256(2.5 ether) * (86400 - 1) / 86400);
        vm.warp(start + 1 days);
        assertEq(staking.pointsOf(alice), 2.5 ether);
        spend(1 ether);
        assertEq(staking.pointsOf(alice), 1.5 ether);
        vm.warp(start + 2 days);
        assertEq(staking.pointsOf(alice), 4 ether);
    }

    function test_AccrueBeforeBalanceChangesAndNoLock() public {
        stake(10 ether);
        vm.warp(block.timestamp + 12 hours);
        stake(10 ether);
        assertEq(staking.pointsOf(alice), 5 ether);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        staking.unstake(20 ether);
        assertEq(staking.pointsOf(alice), 15 ether);
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(vault), 0.2 ether);
        vm.warp(block.timestamp + 100 days);
        assertEq(staking.pointsOf(alice), 15 ether);
        spend(15 ether);
        assertEq(staking.pointsOf(alice), 0);
    }

    function test_CheckpointsPreserveSubWeiAccrualAndFullExitFraction() public {
        stake(1);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i < 25; ++i) {
            vm.warp(start + i * 1 hours);
            spend(0);
        }
        assertEq(staking.pointsOf(alice), 1);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        staking.unstake(1);
        vm.warp(block.timestamp + 100 days);
        stake(1);
        vm.warp(block.timestamp + 12 hours);
        assertEq(staking.pointsOf(alice), 2);
    }

    function testFuzz_CheckpointFrequencyDoesNotChangePoints(uint96 rawBalance, uint32 seconds_, uint8 rawSteps)
        public
    {
        uint256 balance = bound(rawBalance, 1, 1000 ether);
        uint256 elapsed = bound(seconds_, 1, 365 days);
        uint256 steps = bound(rawSteps, 1, 64);
        stake(balance);
        uint256 start = block.timestamp;
        for (uint256 i = 1; i <= steps; ++i) {
            vm.warp(start + elapsed * i / steps);
            spend(0);
        }
        assertEq(staking.pointsOf(alice), balance * elapsed / 86400);
    }

    function testFuzz_FeeRoundsUpAndConservesBalance(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, 1000 ether);
        stake(amount);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(amount);
        uint256 fee = amount / 100 + (amount % 100 == 0 ? 0 : 1);
        assertEq(token.balanceOf(vault), fee);
        assertEq(token.balanceOf(alice) - before, amount - fee);
        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_TinyUnstakesAlwaysPayFee() public {
        stake(101);
        vm.startPrank(alice);
        staking.unstake(1);
        staking.unstake(99);
        staking.unstake(1);
        vm.stopPrank();
        assertEq(token.balanceOf(vault), 3);
    }

    function test_FeeOnTransferCreditsOnlyReceivedAndCannotInflatePoints() public {
        token.configureFee(1000, false);
        stake(100 ether);
        assertEq(staking.stakeOf(alice), 90 ether);
        assertEq(staking.totalStaked(), token.balanceOf(address(staking)));
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.pointsOf(alice), 90 ether);
        vm.prank(alice);
        staking.unstake(90 ether);
        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(token.balanceOf(vault), 0.81 ether);
    }

    function test_ZeroReceiptAndSenderSideFeeRevertAtomically() public {
        token.configureFee(10_000, false);
        vm.expectRevert(OGClubStaking.ZeroAmount.selector);
        stake(100 ether);
        assertEq(staking.totalStaked(), 0);
        token.configureFee(0, false);
        stake(100 ether);
        token.mint(address(staking), 10 ether); // Donation must not fund a sender-side tax.
        token.configureFee(1000, true);
        vm.prank(alice);
        vm.expectRevert(OGClubStaking.UnexpectedTokenDebit.selector);
        staking.unstake(10 ether);
        assertEq(staking.stakeOf(alice), 100 ether);
        assertEq(token.balanceOf(address(staking)), 110 ether);
        assertEq(token.balanceOf(vault), 0);
    }

    function test_DecimalsReadOnFirstUseAndNormalizeWholeTokens() public {
        TestToken six = new TestToken(6);
        OGClubStaking other = new OGClubStaking(six, vault, address(this), 3e18);
        six.mint(alice, 2_500_000);
        vm.startPrank(alice);
        six.approve(address(other), 2_500_000);
        other.stake(2_500_000);
        vm.stopPrank();
        assertEq(other.accrualDenominator(), 86400 * 1e6);
        vm.warp(block.timestamp + 1 days);
        assertEq(other.pointsOf(alice), 7.5 ether);
        TestToken tooMany = new TestToken(19);
        other = new OGClubStaking(tooMany, vault, address(this), 1e18);
        vm.expectRevert(OGClubStaking.UnsupportedDecimals.selector);
        other.stake(1);
    }

    function test_NoReturnAndFalseReturnTokens() public {
        NoReturnToken noReturn = new NoReturnToken();
        OGClubStaking other = new OGClubStaking(IERC20(address(noReturn)), vault, address(this), 1e18);
        noReturn.mint(alice, 1 ether);
        vm.startPrank(alice);
        noReturn.approve(address(other), 1 ether);
        other.stake(1 ether);
        other.unstake(1 ether);
        vm.stopPrank();
        assertEq(noReturn.balanceOf(vault), 0.01 ether);
        token.configureFalse(true);
        vm.expectRevert();
        stake(1 ether);
        assertEq(staking.totalStaked(), 0);
    }

    function test_TokenCallbackCannotSpendOrReenterStakeOrUnstake() public {
        staking.grantSpender(address(token));
        vm.warp(block.timestamp + 7 days);
        staking.activateSpender(address(token));
        token.configureCallback(address(staking), abi.encodeCall(staking.spendPoints, (alice, 0)));
        stake(10 ether);
        assertFalse(token.callbackSucceeded());
        token.configureCallback(address(staking), abi.encodeCall(staking.stake, (1)));
        stake(1 ether);
        assertFalse(token.callbackSucceeded());
        token.configureCallback(address(staking), abi.encodeCall(staking.unstake, (1)));
        vm.prank(alice);
        staking.unstake(1 ether);
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(address(staking)), staking.totalStaked());
    }

    function test_InvalidAmountsUnauthorizedSpendAndOwnerCannotTouchStakes() public {
        vm.expectRevert(OGClubStaking.ZeroAmount.selector);
        stake(0);
        stake(1 ether);
        vm.prank(alice);
        vm.expectRevert(OGClubStaking.InsufficientStake.selector);
        staking.unstake(1 ether + 1);
        vm.prank(alice);
        vm.expectRevert(OGClubStaking.ZeroAmount.selector);
        staking.unstake(0);
        vm.expectRevert(OGClubStaking.NotSpender.selector);
        staking.spendPoints(alice, 1);
        vm.expectRevert(OGClubStaking.InsufficientPoints.selector);
        spend(1);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSignature("setPaused(bool)", true);
        calls[1] = abi.encodeWithSignature("setVault(address)", address(this));
        calls[2] = abi.encodeWithSignature("transferPoints(address,address,uint256)", alice, address(this), 1);
        calls[3] = abi.encodeWithSignature("withdraw(address,uint256)", alice, 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(staking).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(staking.stakeOf(alice), 1 ether);
        assertEq(staking.pointsOf(alice), 0);
    }

    function test_MaximumPackedBalanceAndRateAccrueWithoutIntermediateOverflow() public {
        OGClubStaking other = new OGClubStaking(token, vault, address(this), type(uint96).max);
        uint256 amount = type(uint128).max;
        token.mint(alice, amount);
        vm.startPrank(alice);
        token.approve(address(other), type(uint256).max);
        other.stake(amount);
        vm.stopPrank();
        vm.warp(type(uint48).max);
        assertGt(other.pointsOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        other.stake(1);
        vm.prank(alice);
        other.unstake(amount);
        assertEq(other.totalStaked(), 0);
    }

    function testFuzz_WholeTokenAccrualAcrossSupportedDecimals(uint8 rawDecimals, uint96 rawRate, uint32 rawElapsed)
        public
    {
        uint8 decimals = uint8(bound(rawDecimals, 0, 18));
        uint256 rate = bound(rawRate, 1, type(uint96).max);
        uint256 elapsed = bound(rawElapsed, 0, 365 days);
        TestToken custom = new TestToken(decimals);
        OGClubStaking other = new OGClubStaking(custom, vault, address(this), rate);
        uint256 units = 10 ** uint256(decimals);
        custom.mint(alice, 3 * units);
        vm.startPrank(alice);
        custom.approve(address(other), 3 * units);
        other.stake(3 * units);
        vm.stopPrank();
        vm.warp(block.timestamp + elapsed);
        assertEq(other.pointsOf(alice), 3 * rate * elapsed / 86400);
    }

    function test_DonationsNeitherCreateStakeNorAwardPoints() public {
        stake(1 ether);
        token.mint(address(staking), 100 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.totalStaked(), 1 ether);
        assertEq(staking.pointsOf(alice), 1 ether);
        assertEq(staking.pointsOf(address(this)), 0);
        vm.prank(alice);
        staking.unstake(1 ether);
        assertEq(token.balanceOf(address(staking)), 100 ether);
        assertEq(staking.totalStaked(), 0);
    }
}
