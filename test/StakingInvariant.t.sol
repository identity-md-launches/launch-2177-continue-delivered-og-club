// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {TestToken} from "./helpers/TokenMocks.sol";

contract StakingHandler is Test {
    OGClubStaking public staking;
    TestToken public token;
    address[3] public actors;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public integral;
    mapping(address => uint256) public checkpoint;
    mapping(address => uint256) public spent;
    uint256 public total;
    uint256 public fees;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public spends;

    constructor(OGClubStaking staking_, TestToken token_) {
        staking = staking_;
        token = token_;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("staker-", vm.toString(i)));
            checkpoint[actors[i]] = block.timestamp;
            token.mint(actors[i], 1_000_000 ether);
            vm.prank(actors[i]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    function settle(address who) internal {
        integral[who] += balances[who] * (block.timestamp - checkpoint[who]);
        checkpoint[who] = block.timestamp;
    }

    function stake(uint8 whoSeed, uint96 raw) external {
        address who = actors[whoSeed % 3];
        uint256 available = token.balanceOf(who);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available < 1000 ether ? available : 1000 ether);
        settle(who);
        uint256 received = amount - amount * token.feeBps() / 10_000;
        if (received == 0) return;
        vm.prank(who);
        staking.stake(amount);
        balances[who] += received;
        total += received;
        ++deposits;
    }

    function unstake(uint8 whoSeed, uint96 raw) external {
        address who = actors[whoSeed % 3];
        if (balances[who] == 0) return;
        uint256 amount = bound(raw, 1, balances[who]);
        settle(who);
        uint256 fee = amount / 100 + (amount % 100 == 0 ? 0 : 1);
        fees += fee - fee * token.feeBps() / 10_000;
        vm.prank(who);
        staking.unstake(amount);
        balances[who] -= amount;
        total -= amount;
        ++withdrawals;
    }

    function spend(uint8 whoSeed, uint96 raw) external {
        address who = actors[whoSeed % 3];
        settle(who);
        uint256 available = integral[who] / 86400 - spent[who];
        uint256 amount = bound(raw, 0, available);
        staking.spendPoints(who, amount);
        spent[who] += amount;
        ++spends;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 10 days));
    }

    function unauthorizedSpend(uint8 whoSeed) external {
        address who = actors[whoSeed % 3];
        vm.prank(who);
        vm.expectRevert(OGClubStaking.NotSpender.selector);
        staking.spendPoints(who, 0);
    }
}

abstract contract StakingInvariantBase is Test {
    TestToken internal token;
    OGClubStaking internal staking;
    StakingHandler internal handler;
    address internal vault = makeAddr("fee vault");

    function setup(uint256 fee) internal {
        vm.warp(1_800_000_000);
        token = new TestToken(18);
        token.configureFee(fee, false);
        staking = new OGClubStaking(token, vault, address(this), 1e18);
        handler = new StakingHandler(staking, token);
        staking.grantSpender(address(handler));
        handler.stake(0, 10 ether);
        handler.advance(1 days);
        handler.spend(0, 1 ether);
        handler.unstake(0, 1 ether);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.unauthorizedSpend.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_StakingBalanceEqualsAllStakes() public view {
        assertEq(token.balanceOf(address(staking)), staking.totalStaked());
        assertEq(staking.totalStaked(), handler.total());
        assertEq(token.balanceOf(vault), handler.fees());
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            address who = handler.actors(i);
            assertEq(staking.stakeOf(who), handler.balances(who));
            total += handler.balances(who);
        }
        assertEq(total, staking.totalStaked());
        assertGt(handler.deposits(), 0);
        assertGt(handler.withdrawals(), 0);
    }

    function invariant_PointsAppearOnlyByTimeWeightedAccrualAndLeaveOnlyBySpending() public view {
        for (uint256 i; i < 3; ++i) {
            address who = handler.actors(i);
            uint256 earned = handler.integral(who) + handler.balances(who) * (block.timestamp - handler.checkpoint(who));
            assertEq(staking.pointsOf(who) + handler.spent(who), earned / 86400);
        }
        assertEq(staking.pointsOf(address(this)), 0);
        assertGt(handler.spends(), 0);
    }
}

contract StakingInvariantTest is StakingInvariantBase {
    function setUp() public {
        setup(0);
    }
}

contract FeeStakingInvariantTest is StakingInvariantBase {
    function setUp() public {
        setup(200);
    }
}
