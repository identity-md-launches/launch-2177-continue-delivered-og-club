// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OGClubRaffle} from "src/OGClubRaffle.sol";
import {OGClubStaking} from "src/OGClubStaking.sol";
import {OGClubFurniture} from "src/OGClubFurniture.sol";
import {OGClubFarmVault} from "src/OGClubFarmVault.sol";
import {MockOG} from "src/mocks/MockOG.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @dev Models purchases and mint receipts independently. Draw outputs are checked as
/// permutations and then snapshotted to detect any later change in a winner or prize.
contract RaffleSequenceHandler is Test {
    OGClubRaffle public immutable raffle;
    OGClubStaking public immutable staking;
    OGClubFurniture public immutable furniture;
    uint256 public immutable start;
    address[4] public actors;
    uint256[4] public pointsSpent;
    uint256 public count;
    uint256 public minted;
    uint256 public successfulEntries;
    uint256 public successfulDraws;
    uint256 public successfulClaims;
    uint256 public rejectedClaims;

    struct RaffleModel {
        uint256 opensAt;
        uint256 closesAt;
        uint256 target;
        bool cancelled;
        bool drawn;
        bytes32 seed;
    }

    struct EntryModel {
        uint256 actor;
        uint256 first;
        uint256 end;
    }

    struct PoolModel {
        uint256 sold;
        uint256[4] tickets;
        EntryModel[] entries;
        uint256[6] winningTickets;
        uint256[6] prizes;
        bool[6] claimed;
    }

    mapping(uint256 => RaffleModel) public models;
    mapping(uint256 => mapping(uint256 => PoolModel)) internal pools;
    mapping(uint256 => uint256[4]) public receipts;

    constructor(OGClubRaffle raffle_, OGClubStaking staking_, OGClubFurniture furniture_, MockOG token) {
        raffle = raffle_;
        staking = staking_;
        furniture = furniture_;
        start = vm.getBlockTimestamp();
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("raffle-sequence-actor-", vm.toString(i)));
            token.mint(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(staking), type(uint256).max);
            staking.stake(1000 ether);
            vm.stopPrank();
        }
    }

    function acceptOwnership() external {
        raffle.acceptOwnership();
    }

    function poolModel(uint256 id, uint256 p) external view returns (PoolModel memory) {
        return pools[id][p];
    }

    function price(uint256 p) public pure returns (uint256) {
        return (p + 1) * 1e15 + 7;
    }

    function item(uint256 id, uint256 p, uint256 line) public pure returns (uint256) {
        return id * 100 + p * 10 + line;
    }

    function create(uint32 delaySeed) public {
        if (count == 4) return;
        uint256 opens = vm.getBlockTimestamp() + bound(delaySeed, 0, 1 days);
        OGClubRaffle.PoolInput[] memory input = new OGClubRaffle.PoolInput[](2);
        uint256 id = count + 1;
        for (uint256 p; p < 2; ++p) {
            OGClubRaffle.Prize[] memory prizes = new OGClubRaffle.Prize[](3);
            for (uint256 j; j < 3; ++j) {
                prizes[j] = OGClubRaffle.Prize(item(id, p, j), j + 1);
            }
            input[p] = OGClubRaffle.PoolInput(uint8(p + 3), price(p), p == 0 ? 8 : 0, prizes);
        }
        assertEq(raffle.createRaffle(opens, opens + 5 days, input), id);
        models[id] = RaffleModel(opens, opens + 5 days, 0, false, false, bytes32(0));
        count = id;
    }

    function enter(uint8 raffleSeed, uint8 poolSeed, uint8 actorSeed, uint8 ticketSeed) public {
        uint256 id = 1 + raffleSeed % count;
        uint256 p = poolSeed % 2;
        uint256 a = actorSeed % 4;
        uint256 tickets = bound(ticketSeed, 0, 10);
        RaffleModel storage r = models[id];
        PoolModel storage m = pools[id][p];
        if (r.cancelled) {
            vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        } else if (vm.getBlockTimestamp() < r.opensAt || vm.getBlockTimestamp() >= r.closesAt) {
            vm.expectRevert(OGClubRaffle.EntryClosed.selector);
        } else if (tickets == 0) {
            vm.expectRevert(OGClubRaffle.InvalidTickets.selector);
        } else if (p == 0 && m.tickets[a] + tickets > 8) {
            vm.expectRevert(OGClubRaffle.WalletCapExceeded.selector);
        } else {
            vm.prank(actors[a]);
            assertEq(raffle.enter(id, p, tickets), m.entries.length);
            m.entries.push(EntryModel(a, m.sold, m.sold + tickets));
            m.sold += tickets;
            m.tickets[a] += tickets;
            pointsSpent[a] += tickets * price(p);
            ++successfulEntries;
            return;
        }
        vm.prank(actors[a]);
        raffle.enter(id, p, tickets);
    }

    function advance(uint32 secondsSeed, uint16 blocksSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 2 days));
        vm.roll(vm.getBlockNumber() + bound(blocksSeed, 0, 300));
    }

    function cancel(uint8 raffleSeed) public {
        uint256 id = 1 + raffleSeed % count;
        RaffleModel storage r = models[id];
        if (r.cancelled) {
            vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        } else if (vm.getBlockTimestamp() >= r.opensAt) {
            vm.expectRevert(OGClubRaffle.AlreadyStarted.selector);
        } else {
            raffle.cancelRaffle(id);
            r.cancelled = true;
            return;
        }
        raffle.cancelRaffle(id);
    }

    function commit(uint8 raffleSeed) public {
        uint256 id = 1 + raffleSeed % count;
        RaffleModel storage r = models[id];
        if (r.cancelled) {
            vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        } else if (vm.getBlockTimestamp() < r.closesAt) {
            vm.expectRevert(OGClubRaffle.RaffleStillOpen.selector);
        } else if (r.drawn) {
            vm.expectRevert(OGClubRaffle.AlreadyDrawn.selector);
        } else if (r.target != 0 && vm.getBlockNumber() <= r.target + 256) {
            vm.expectRevert(OGClubRaffle.TargetStillLive.selector);
        } else {
            vm.prank(actors[3]);
            raffle.commitDraw(id);
            r.target = vm.getBlockNumber() + 3;
            return;
        }
        raffle.commitDraw(id);
    }

    function draw(uint8 raffleSeed, uint16 offsetSeed, bool corrupt) public {
        uint256 id = 1 + raffleSeed % count;
        RaffleModel storage r = models[id];
        uint256 nextBlock = r.target + bound(offsetSeed, 0, 257);
        if (nextBlock > vm.getBlockNumber()) vm.roll(nextBlock);
        // Identical block numbers always have identical headers, including across different raffles.
        bytes32 seed = keccak256(abi.encode("sequence block", r.target));
        bytes memory header = HeaderBuilder.header(r.target, seed, 9);
        bool available = r.target != 0 && vm.getBlockNumber() > r.target && vm.getBlockNumber() <= r.target + 256;
        if (available) vm.setBlockhash(r.target, keccak256(header));
        if (corrupt) header = HeaderBuilder.header(r.target, ~seed, 9);
        if (r.cancelled) {
            vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        } else if (r.drawn) {
            vm.expectRevert(OGClubRaffle.AlreadyDrawn.selector);
        } else if (!available) {
            vm.expectRevert(OGClubRaffle.TargetUnavailable.selector);
        } else if (corrupt) {
            vm.expectRevert(OGClubRaffle.InvalidHeader.selector);
        } else {
            vm.prank(actors[2]);
            raffle.draw(id, header);
            r.drawn = true;
            r.seed = seed;
            snapshotWinners(id);
            ++successfulDraws;
            return;
        }
        raffle.draw(id, header);
    }

    function snapshotWinners(uint256 id) internal {
        for (uint256 p; p < 2; ++p) {
            PoolModel storage m = pools[id][p];
            uint256 wins = m.sold < 6 ? m.sold : 6;
            assertEq(raffle.winnerCount(id, p), wins);
            uint256[3] memory quantities;
            for (uint256 k; k < wins; ++k) {
                uint256 ticket = raffle.winningTicket(id, p, k);
                uint256 prize = raffle.prizeOf(id, p, k);
                assertLt(ticket, m.sold);
                for (uint256 j; j < k; ++j) {
                    assertNotEq(ticket, m.winningTickets[j], "duplicate winner");
                }
                assertGe(prize, item(id, p, 0));
                assertLe(prize, item(id, p, 2));
                ++quantities[prize - item(id, p, 0)];
                m.winningTickets[k] = ticket;
                m.prizes[k] = prize;
            }
            for (uint256 j; j < 3; ++j) {
                assertLe(quantities[j], j + 1, "prize quantity exceeded");
                if (m.sold >= 6) assertEq(quantities[j], j + 1, "prize omitted");
            }
        }
    }

    function entryFor(uint256 id, uint256 p, uint256 k) internal view returns (uint256) {
        PoolModel storage m = pools[id][p];
        for (uint256 e; e < m.entries.length; ++e) {
            if (m.winningTickets[k] >= m.entries[e].first && m.winningTickets[k] < m.entries[e].end) return e;
        }
        revert("harness: ticket outside all purchased ranges");
    }

    function claim(uint8 raffleSeed, uint8 poolSeed, uint8 winSeed, uint8 toSeed, bool redirect) public {
        uint256 id = 1 + raffleSeed % count;
        uint256 p = poolSeed % 2;
        PoolModel storage m = pools[id][p];
        if (!models[id].drawn || m.sold == 0) return;
        uint256 wins = m.sold < 6 ? m.sold : 6;
        uint256 k = winSeed % wins;
        uint256 e = entryFor(id, p, k);
        uint256 recipient = redirect ? toSeed % 4 : m.entries[e].actor;
        OGClubRaffle.Win[] memory list = new OGClubRaffle.Win[](1);
        list[0] = OGClubRaffle.Win(k, e);
        bool wasClaimed = m.claimed[k];
        if (wasClaimed) vm.expectRevert(OGClubRaffle.AlreadyClaimed.selector);
        if (redirect) {
            vm.prank(actors[m.entries[e].actor]);
            raffle.claimTo(id, p, list, actors[recipient]);
        } else {
            vm.prank(actors[(recipient + 1) % 4]);
            raffle.claim(id, p, list);
        }
        if (!wasClaimed) {
            m.claimed[k] = true;
            ++receipts[m.prizes[k]][recipient];
            ++minted;
            ++successfulClaims;
        }
    }

    function badClaim(uint8 raffleSeed, uint8 poolSeed, uint8 winSeed, uint8 modeSeed) public {
        uint256 id = 1 + raffleSeed % count;
        uint256 p = poolSeed % 2;
        PoolModel storage m = pools[id][p];
        if (!models[id].drawn || m.sold == 0) return;
        uint256 wins = m.sold < 6 ? m.sold : 6;
        uint256 k = winSeed % wins;
        uint256 e = entryFor(id, p, k);
        uint256 mode = modeSeed % 5;
        OGClubRaffle.Win[] memory list = new OGClubRaffle.Win[](mode == 2 ? 2 : 1);
        list[0] = OGClubRaffle.Win(k, e);
        if (mode == 0) {
            list[0].entry = m.entries.length;
            vm.expectRevert(OGClubRaffle.InvalidEntry.selector);
        } else if (mode == 1) {
            list[0].k = wins;
            vm.expectRevert(OGClubRaffle.InvalidWin.selector);
        } else if (mode == 2) {
            list[1] = list[0];
            vm.expectRevert(OGClubRaffle.AlreadyClaimed.selector);
        } else if (mode == 3) {
            vm.prank(actors[(m.entries[e].actor + 1) % 4]);
            vm.expectRevert(OGClubRaffle.NotEntryWallet.selector);
            raffle.claimTo(id, p, list, actors[0]);
            ++rejectedClaims;
            return;
        } else {
            if (m.entries.length < 2) return;
            list[0].entry = (e + 1) % m.entries.length;
            vm.expectRevert(OGClubRaffle.InvalidEntry.selector);
        }
        raffle.claim(id, p, list);
        ++rejectedClaims;
    }

    function finish() external {
        // Complete every noncancelled raffle and pay every remaining win after a random history.
        for (uint8 i; i < count; ++i) {
            RaffleModel storage r = models[uint256(i) + 1];
            if (r.cancelled) continue;
            if (vm.getBlockTimestamp() < r.closesAt) vm.warp(r.closesAt);
            if (!r.drawn) {
                if (r.target == 0 || vm.getBlockNumber() > r.target + 256) commit(i);
                draw(i, 1, false);
            }
            for (uint8 p; p < 2; ++p) {
                PoolModel storage m = pools[uint256(i) + 1][p];
                uint256 wins = m.sold < 6 ? m.sold : 6;
                for (uint8 k; k < wins; ++k) {
                    if (!m.claimed[k]) claim(i, p, k, 0, false);
                }
            }
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract RaffleSequenceInvariantTest is Test {
    MockOG internal token;
    OGClubStaking internal staking;
    OGClubFarmVault internal vault;
    OGClubFurniture internal furniture;
    OGClubRaffle internal raffle;
    RaffleSequenceHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 1e18);
        raffle = new OGClubRaffle(staking, furniture, address(this), 0);
        furniture.grantMinter(address(raffle));
        staking.grantSpender(address(raffle));
        handler = new RaffleSequenceHandler(raffle, staking, furniture, token);
        raffle.transferOwnership(address(handler));
        handler.acceptOwnership();
        handler.advance(1 days, 0);
        handler.create(0);
        handler.enter(0, 0, 0, 5);
        handler.enter(0, 0, 1, 5);
        handler.enter(0, 1, 2, 2);
        handler.enter(0, 1, 3, 1); // This pool deliberately has unawarded prizes.
        for (uint256 i; i < 3; ++i) {
            handler.advance(2 days, 0);
        }
        handler.commit(0);
        handler.draw(0, 1, false);
        handler.badClaim(0, 0, 0, 2); // Duplicate batch must undo its first consumption/mint.
        handler.claim(0, 0, 0, 3, true);
        handler.create(1 days);
        handler.cancel(1);
        handler.create(0);
        handler.enter(2, 1, 0, 4);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.enter.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.commit.selector;
        selectors[5] = handler.draw.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.badClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_PointsSpentExactlyMatchAcceptedRanges() public view {
        uint256[4] memory spent;
        for (uint256 id = 1; id <= handler.count(); ++id) {
            (,,, bool cancelled,,) = handler.models(id);
            if (cancelled) continue;
            for (uint256 p; p < 2; ++p) {
                RaffleSequenceHandler.PoolModel memory m = handler.poolModel(id, p);
                (uint8 tier, uint256 price, uint256 cap, uint256 sold, uint256 prizes, uint256 entries) =
                    raffle.getPool(id, p);
                assertEq(tier, p + 3);
                assertEq(price, handler.price(p));
                assertEq(cap, p == 0 ? 8 : 0);
                assertEq(prizes, 6);
                assertEq(sold, m.sold);
                assertEq(entries, m.entries.length);
                uint256 end;
                for (uint256 e; e < entries; ++e) {
                    OGClubRaffle.Entry memory actual = raffle.getEntry(id, p, e);
                    assertEq(actual.first, end, "ticket ranges must be contiguous");
                    assertEq(actual.first, m.entries[e].first);
                    assertEq(actual.end, m.entries[e].end);
                    assertGt(actual.end, actual.first);
                    assertEq(actual.wallet, handler.actors(m.entries[e].actor));
                    end = actual.end;
                }
                assertEq(end, sold);
                uint256 sum;
                for (uint256 a; a < 4; ++a) {
                    assertEq(raffle.ticketsOf(id, p, handler.actors(a)), m.tickets[a]);
                    if (cap != 0) assertLe(m.tickets[a], cap);
                    sum += m.tickets[a];
                    spent[a] += m.tickets[a] * price;
                }
                assertEq(sum, sold);
            }
        }
        for (uint256 a; a < 4; ++a) {
            assertEq(spent[a], handler.pointsSpent(a));
            assertEq(
                staking.pointsOf(handler.actors(a)) + spent[a],
                1000 ether * (vm.getBlockTimestamp() - handler.start()) / 1 days
            );
        }
        assertEq(token.balanceOf(address(staking)), 4000 ether);
        assertEq(staking.totalStaked(), 4000 ether);
    }

    function invariant_FinalizedDrawsAndTermsNeverChange() public view {
        assertEq(raffle.raffleCount(), handler.count());
        for (uint256 id = 1; id <= handler.count(); ++id) {
            {
                (uint256 opens, uint256 closes, uint256 target, bool cancelled, bool expectedDrawn, bytes32 seed) =
                    handler.models(id);
                (uint64 o, uint64 c, uint64 t, uint8 n, bool x, bool d, bytes32 s) = raffle.raffles(id);
                assertEq(o, opens);
                assertEq(c, closes);
                assertEq(t, target);
                assertEq(n, 2);
                assertEq(x, cancelled);
                assertEq(d, expectedDrawn);
                assertEq(s, seed);
            }
            (,,,, bool drawn,) = handler.models(id);
            if (!drawn) continue;
            for (uint256 p; p < 2; ++p) {
                RaffleSequenceHandler.PoolModel memory m = handler.poolModel(id, p);
                uint256 wins = m.sold < 6 ? m.sold : 6;
                assertEq(raffle.winnerCount(id, p), wins);
                for (uint256 k; k < wins; ++k) {
                    assertEq(raffle.winningTicket(id, p, k), m.winningTickets[k]);
                    assertEq(raffle.prizeOf(id, p, k), m.prizes[k]);
                }
            }
        }
    }

    function invariant_ClaimBitsMatchMintReceiptsAndNeverMintUnawardedPrizes() public view {
        uint256 claimedCount;
        for (uint256 id = 1; id <= handler.count(); ++id) {
            for (uint256 p; p < 2; ++p) {
                RaffleSequenceHandler.PoolModel memory m = handler.poolModel(id, p);
                uint256[3] memory quantities;
                for (uint256 k; k < 6; ++k) {
                    assertEq(raffle.isClaimed(id, p, k), m.claimed[k]);
                    if (m.claimed[k]) {
                        ++claimedCount;
                        ++quantities[m.prizes[k] - handler.item(id, p, 0)];
                    }
                }
                for (uint256 j; j < 3; ++j) {
                    uint256 itemId = handler.item(id, p, j);
                    assertLe(quantities[j], j + 1);
                    assertEq(furniture.totalSupply(itemId), quantities[j]);
                    uint256 sum;
                    for (uint256 a; a < 4; ++a) {
                        uint256 received = handler.receipts(itemId, a);
                        assertEq(furniture.balanceOf(handler.actors(a), itemId), received);
                        sum += received;
                    }
                    assertEq(sum, quantities[j]);
                }
            }
        }
        assertEq(furniture.totalSupply(), claimedCount);
        assertEq(claimedCount, handler.minted());
        assertGt(handler.successfulEntries(), 0);
        assertGt(handler.successfulDraws(), 0);
        assertGt(handler.successfulClaims(), 0);
        assertGt(handler.rejectedClaims(), 0);
    }

    function afterInvariant() public {
        handler.finish();
        invariant_PointsSpentExactlyMatchAcceptedRanges();
        invariant_FinalizedDrawsAndTermsNeverChange();
        invariant_ClaimBitsMatchMintReceiptsAndNeverMintUnawardedPrizes();
        uint256 expected;
        for (uint256 id = 1; id <= handler.count(); ++id) {
            (,,, bool cancelled,,) = handler.models(id);
            if (cancelled) continue;
            for (uint256 p; p < 2; ++p) {
                expected += raffle.winnerCount(id, p);
            }
        }
        assertEq(furniture.totalSupply(), expected, "every remaining win must remain claimable");
    }
}
