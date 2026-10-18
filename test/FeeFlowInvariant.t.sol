// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OGClubStaking} from "src/OGClubStaking.sol";
import {OGClubFarmVault} from "src/OGClubFarmVault.sol";
import {TestToken} from "./helpers/TokenMocks.sol";

/// @dev A closed economy: the only tokens are the four actors' initial allocations.
/// Seasons are funded by actual unstake fees. Claims can be restaked and taxed again.
contract FeeFlowHandler is Test {
    uint256 public constant INITIAL = 1_000_000 * 1e6;
    uint256 public constant RATE = 3e18 + 17;
    TestToken public immutable token;
    OGClubStaking public immutable staking;
    OGClubFarmVault public immutable vault;
    uint256 public immutable taxBps;
    address[4] public actors;
    uint256[4] public liquid;
    uint256[4] public staked;
    uint256[4] public integral;
    uint256[4] public checkpoint;
    uint256[4] public spent;
    uint256 public burned;
    uint256 public feeReceipts;
    uint256 public payouts;
    uint256 public reservations;
    uint256 public lastProposal;
    uint256 public successfulClaims;
    uint256 public successfulReleases;
    uint256 public successfulCancels;

    struct SeasonModel {
        bytes32 root;
        uint256 opensAt;
        uint256 remaining;
        uint256[4] amounts;
        bool[4] paid;
        bool closed;
    }

    SeasonModel[] internal model;

    constructor(TestToken token_, OGClubStaking staking_, OGClubFarmVault vault_, uint256 taxBps_) {
        token = token_;
        staking = staking_;
        vault = vault_;
        taxBps = taxBps_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("fee-flow-actor-", vm.toString(i)));
            token.mint(actors[i], INITIAL);
            liquid[i] = INITIAL;
            checkpoint[i] = vm.getBlockTimestamp();
            vm.prank(actors[i]);
            token.approve(address(staking), type(uint256).max);
        }
    }

    function acceptOwnership() external {
        vault.acceptOwnership();
    }

    function count() external view returns (uint256) {
        return model.length;
    }

    function season(uint256 i) external view returns (SeasonModel memory) {
        return model[i];
    }

    function net(uint256 amount) public view returns (uint256) {
        return amount - amount * taxBps / 10_000;
    }

    function settle(uint256 actor) internal {
        integral[actor] += staked[actor] * (vm.getBlockTimestamp() - checkpoint[actor]);
        checkpoint[actor] = vm.getBlockTimestamp();
    }

    function earned(uint256 actor) public view returns (uint256) {
        uint256 area = integral[actor] + staked[actor] * (vm.getBlockTimestamp() - checkpoint[actor]);
        // One division over the entire balance-time integral; independent of contract checkpoints.
        return area * RATE / (1e6 * 1 days);
    }

    function stake(uint8 actorSeed, uint96 raw) public {
        uint256 a = actorSeed % 4;
        if (liquid[a] == 0) return;
        uint256 amount = bound(raw, 1, liquid[a]);
        settle(a);
        vm.prank(actors[a]);
        staking.stake(amount);
        liquid[a] -= amount;
        staked[a] += net(amount);
        burned += amount - net(amount);
    }

    function unstake(uint8 actorSeed, uint96 raw) public {
        uint256 a = actorSeed % 4;
        if (staked[a] == 0) return;
        uint256 amount = bound(raw, 1, staked[a]);
        settle(a);
        vm.prank(actors[a]);
        staking.unstake(amount);
        uint256 fee = (amount + 99) / 100;
        uint256 returned = net(amount - fee);
        uint256 receivedFee = net(fee);
        staked[a] -= amount;
        liquid[a] += returned;
        feeReceipts += receivedFee;
        burned += amount - returned - receivedFee;
    }

    function exit(uint8 actorSeed) external {
        uint256 a = actorSeed % 4;
        unstake(actorSeed, uint96(staked[a]));
    }

    function spend(uint8 actorSeed, uint96 raw) public {
        uint256 a = actorSeed % 4;
        uint256 amount = bound(raw, 0, earned(a) - spent[a]);
        staking.spendPoints(actors[a], amount);
        spent[a] += amount;
    }

    function overspend(uint8 actorSeed) external {
        uint256 a = actorSeed % 4;
        vm.expectRevert(OGClubStaking.InsufficientPoints.selector);
        staking.spendPoints(actors[a], earned(a) - spent[a] + 1);
    }

    function advance(uint32 raw) public {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 15 days));
    }

    function propose(uint96 raw) public {
        if (model.length != 0 && vm.getBlockTimestamp() < lastProposal + 7 days) return;
        uint256 available = (feeReceipts - payouts - reservations) / 2;
        if (available < 4) return;
        uint256 amount = bound(raw, 4, available);
        uint256 id = model.length + 1;
        SeasonModel memory s;
        s.opensAt = vm.getBlockTimestamp() + 3 days;
        s.remaining = amount;
        for (uint256 i; i < 4; ++i) {
            s.amounts[i] = amount / 4 + (i == 3 ? amount % 4 : 0);
        }
        s.root = pair(
            pair(leaf(id, 0, s.amounts[0]), leaf(id, 1, s.amounts[1])),
            pair(leaf(id, 2, s.amounts[2]), leaf(id, 3, s.amounts[3]))
        );
        assertEq(vault.proposeSeason(s.root, amount), id);
        model.push(s);
        reservations += amount;
        lastProposal = vm.getBlockTimestamp();
    }

    function claim(uint8 seasonSeed, uint8 actorSeed) public {
        if (model.length == 0) return;
        uint256 i = seasonSeed % model.length;
        uint256 a = actorSeed % 4;
        SeasonModel storage s = model[i];
        bytes32[] memory p = proof(i, a);
        if (vm.getBlockTimestamp() < s.opensAt) {
            vm.expectRevert(OGClubFarmVault.ClaimsNotOpen.selector);
        } else if (s.closed || vm.getBlockTimestamp() >= s.opensAt + 90 days) {
            vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        } else if (s.paid[a]) {
            vm.expectRevert(OGClubFarmVault.AlreadyClaimed.selector);
        } else {
            vm.prank(actors[(a + 1) % 4]); // A different wallet submits; the allocation recipient gets the funds.
            vault.claim(i + 1, actors[a], s.amounts[a], p);
            s.paid[a] = true;
            s.remaining -= s.amounts[a];
            reservations -= s.amounts[a];
            payouts += s.amounts[a];
            liquid[a] += net(s.amounts[a]);
            burned += s.amounts[a] - net(s.amounts[a]);
            ++successfulClaims;
            return;
        }
        vault.claim(i + 1, actors[a], s.amounts[a], p);
    }

    function badProof(uint8 seasonSeed, uint8 actorSeed) external {
        if (model.length == 0) return;
        uint256 i = seasonSeed % model.length;
        uint256 a = actorSeed % 4;
        SeasonModel storage s = model[i];
        if (
            s.closed || s.paid[a] || vm.getBlockTimestamp() < s.opensAt || vm.getBlockTimestamp() >= s.opensAt + 90 days
        ) return;
        bytes32[] memory p = proof(i, a);
        vm.expectRevert(OGClubFarmVault.InvalidProof.selector);
        vault.claim(i + 1, actors[a], s.amounts[a] + 1, p);
    }

    function cancel(uint8 seasonSeed) public {
        if (model.length == 0) return;
        uint256 i = seasonSeed % model.length;
        SeasonModel storage s = model[i];
        if (s.closed) {
            vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        } else if (vm.getBlockTimestamp() >= s.opensAt) {
            vm.expectRevert(OGClubFarmVault.CancellationTooLate.selector);
        } else {
            vault.cancelSeason(i + 1);
            reservations -= s.remaining;
            s.remaining = 0;
            s.closed = true;
            ++successfulCancels;
            return;
        }
        vault.cancelSeason(i + 1);
    }

    function release(uint8 seasonSeed) public {
        if (model.length == 0) return;
        uint256 i = seasonSeed % model.length;
        SeasonModel storage s = model[i];
        if (s.closed) {
            vm.expectRevert(OGClubFarmVault.ClaimsClosed.selector);
        } else if (vm.getBlockTimestamp() < s.opensAt + 90 days) {
            vm.expectRevert(OGClubFarmVault.ReleaseTooEarly.selector);
        } else {
            vault.releaseSeason(i + 1);
            reservations -= s.remaining;
            s.remaining = 0;
            s.closed = true;
            ++successfulReleases;
            return;
        }
        vault.releaseSeason(i + 1);
    }

    function leaf(uint256 id, uint256 a, uint256 amount) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, actors[a], amount))));
    }

    function pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function proof(uint256 i, uint256 a) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        uint256[4] storage amounts = model[i].amounts;
        p[0] = leaf(i + 1, a ^ 1, amounts[a ^ 1]);
        uint256 other = a < 2 ? 2 : 0;
        p[1] = pair(leaf(i + 1, other, amounts[other]), leaf(i + 1, other + 1, amounts[other + 1]));
    }
}

abstract contract FeeFlowInvariantBase is Test {
    TestToken internal token;
    OGClubStaking internal staking;
    OGClubFarmVault internal vault;
    FeeFlowHandler internal handler;

    function setup(uint256 taxBps) internal {
        vm.warp(1_800_000_000);
        token = new TestToken(6);
        token.configureFee(taxBps, false);
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 3e18 + 17);
        handler = new FeeFlowHandler(token, staking, vault, taxBps);
        staking.grantSpender(address(handler));
        vault.transferOwnership(address(handler));
        handler.acceptOwnership();

        // Seed every economic transition, including a partially paid, later released season.
        for (uint8 i; i < 4; ++i) {
            handler.stake(i, 100_000 * 1e6);
        }
        handler.unstake(0, 50_000 * 1e6);
        handler.propose(100 * 1e6);
        handler.cancel(0);
        handler.advance(7 days);
        handler.propose(100 * 1e6);
        handler.advance(3 days);
        handler.claim(1, 0);
        handler.spend(1, 1e18);
        for (uint256 i; i < 6; ++i) {
            handler.advance(15 days);
        }
        handler.release(1);
        handler.propose(40 * 1e6);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.unstake.selector;
        selectors[2] = handler.exit.selector;
        selectors[3] = handler.spend.selector;
        selectors[4] = handler.overspend.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.propose.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.badProof.selector;
        selectors[9] = handler.cancel.selector;
        selectors[10] = handler.release.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_TokensConservedAcrossStakeFeeVaultPayoutAndBurn() public view {
        uint256 total;
        uint256 wallets;
        for (uint256 a; a < 4; ++a) {
            assertEq(staking.stakeOf(handler.actors(a)), handler.staked(a), "individual stake");
            assertEq(token.balanceOf(handler.actors(a)), handler.liquid(a), "individual token receipts");
            total += handler.staked(a);
            wallets += handler.liquid(a);
        }
        assertEq(staking.totalStaked(), total);
        assertEq(token.balanceOf(address(staking)), total);
        assertEq(token.balanceOf(address(vault)), handler.feeReceipts() - handler.payouts());
        assertEq(wallets + total + token.balanceOf(address(vault)) + handler.burned(), 4 * handler.INITIAL());
        assertEq(token.totalSupply() + handler.burned(), 4 * handler.INITIAL());
        assertEq(token.balanceOf(address(this)), 0, "owner has no custody");
        assertEq(token.balanceOf(address(handler)), 0, "spender has no custody");
    }

    function invariant_PointsConservedThroughPartialExitsClaimsAndRestakes() public view {
        for (uint256 a; a < 4; ++a) {
            assertEq(staking.pointsOf(handler.actors(a)) + handler.spent(a), handler.earned(a));
            (,, uint80 remainder,) = staking.accounts(handler.actors(a));
            assertLt(remainder, 1e6 * 1 days);
        }
        assertEq(staking.pointsOf(address(handler)), 0);
    }

    function invariant_EachReservationEqualsUnpaidAllocationsOfAnOpenSeason() public view {
        uint256 sum;
        assertEq(vault.seasonCount(), handler.count());
        assertEq(vault.lastProposedAt(), handler.lastProposal());
        for (uint256 i; i < handler.count(); ++i) {
            FeeFlowHandler.SeasonModel memory s = handler.season(i);
            (bytes32 root, uint256 remaining, uint256 opensAt, bool closed) = vault.seasons(i + 1);
            assertEq(root, s.root, "root immutable");
            assertEq(opensAt, s.opensAt, "opening immutable");
            assertEq(closed, s.closed);
            uint256 unpaid;
            for (uint256 a; a < 4; ++a) {
                assertEq(vault.claimed(i + 1, handler.actors(a)), s.paid[a]);
                if (!s.paid[a] && !s.closed) unpaid += s.amounts[a];
            }
            assertEq(remaining, unpaid);
            assertEq(remaining, s.remaining);
            sum += remaining;
        }
        assertEq(vault.reserved(), sum);
        assertEq(vault.reserved(), handler.reservations());
        assertGe(token.balanceOf(address(vault)), sum);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.successfulCancels(), 0);
        assertGt(handler.successfulReleases(), 0);
    }

    function afterInvariant() public {
        // Withdrawal liveness after arbitrary interleavings, including outstanding seasons.
        for (uint8 a; a < 4; ++a) {
            handler.exit(a);
        }
        invariant_TokensConservedAcrossStakeFeeVaultPayoutAndBurn();
        invariant_PointsConservedThroughPartialExitsClaimsAndRestakes();
        invariant_EachReservationEqualsUnpaidAllocationsOfAnOpenSeason();
        assertEq(staking.totalStaked(), 0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract FeeFlowInvariantTest is FeeFlowInvariantBase {
    function setUp() public {
        setup(0);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract TaxedFeeFlowInvariantTest is FeeFlowInvariantBase {
    function setUp() public {
        setup(750);
    }
}
