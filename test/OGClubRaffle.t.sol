// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RaffleTestBase} from "./helpers/RaffleTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract ClaimWallet is ERC1155Holder {
    address public target;
    bytes public data;
    bool public reject;
    bool public callbackSucceeded;

    function configure(address target_, bytes calldata data_, bool reject_) external {
        target = target_;
        data = data_;
        reject = reject_;
    }

    function execute(address to, bytes calldata call_) external returns (bytes memory result) {
        bool success;
        (success, result) = to.call(call_);
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public override returns (bytes4) {
        require(!reject, "receiver rejects");
        if (target != address(0)) (callbackSucceeded,) = target.call(data);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        override
        returns (bytes4)
    {
        require(!reject, "receiver rejects");
        if (target != address(0)) (callbackSucceeded,) = target.call(data);
        return this.onERC1155BatchReceived.selector;
    }
}

contract RaffleTest is RaffleTestBase {
    function test_NoticeExactBoundariesAndCancellation() public {
        raffle = new OGClubRaffle(staking, furniture, address(this), 7 days);
        uint256 opening = block.timestamp + 7 days;
        vm.expectRevert(OGClubRaffle.InsufficientNotice.selector);
        raffle.createRaffle(opening - 1, opening + 1 days, pools(1));
        uint256 id = raffle.createRaffle(opening, opening + 1 days, pools(1));
        vm.warp(opening - 1);
        raffle.cancelRaffle(id);
        vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        raffle.cancelRaffle(id);
        vm.expectRevert(OGClubRaffle.RaffleCancelled.selector);
        raffle.enter(id, 0, 1);
        id = raffle.createRaffle(block.timestamp + 7 days, block.timestamp + 8 days, pools(1));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(OGClubRaffle.AlreadyStarted.selector);
        raffle.cancelRaffle(id);
    }

    function testFuzz_NoticeAlwaysMeasuredFromCreation(uint32 delay) public {
        uint256 notice = bound(delay, 0, 30 days);
        raffle = new OGClubRaffle(staking, furniture, address(this), notice);
        vm.warp(block.timestamp + 100 days);
        uint256 earliest = block.timestamp + notice;
        vm.expectRevert(OGClubRaffle.InsufficientNotice.selector);
        raffle.createRaffle(earliest - 1, earliest + 1 days, pools(1));
        raffle.createRaffle(earliest, earliest + 1 days, pools(1));
    }

    function test_EntryWindowAndWalletCapExactBoundaries() public {
        OGClubRaffle.PoolInput[] memory input = pools(5);
        input[0].maxTicketsPerWallet = 3;
        uint256 opening = block.timestamp + 10;
        uint256 closing = opening + 100;
        uint256 id = raffle.createRaffle(opening, closing, input);
        vm.warp(opening - 1);
        vm.expectRevert(OGClubRaffle.EntryClosed.selector);
        enter(id, alice, 1);
        vm.warp(opening);
        uint256 before = staking.pointsOf(alice);
        enter(id, alice, 1);
        enter(id, alice, 2);
        assertEq(staking.pointsOf(alice), before - 3 ether);
        assertEq(raffle.ticketsOf(id, 0, alice), 3);
        vm.expectRevert(OGClubRaffle.WalletCapExceeded.selector);
        enter(id, alice, 1);
        OGClubRaffle.Entry memory entry = raffle.getEntry(id, 0, 1);
        assertEq(entry.wallet, alice);
        assertEq(entry.first, 1);
        assertEq(entry.end, 3);
        vm.warp(closing - 1);
        enter(id, bob, 3);
        vm.warp(closing);
        vm.expectRevert(OGClubRaffle.EntryClosed.selector);
        enter(id, bob, 1);
        raffle.commitDraw(id);
    }

    function test_UnlimitedCapIsPerPoolAndRangesStayContiguous() public {
        OGClubRaffle.PoolInput[] memory input = new OGClubRaffle.PoolInput[](2);
        input[0] = pools(3)[0];
        input[1] = pools(4)[0];
        input[1].tier = 255; // Tier is display metadata, not odds.
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1 days, input);
        enter(id, alice, 300);
        enter(id, bob, 200);
        enter(id, alice, 400);
        vm.prank(alice);
        raffle.enter(id, 1, 200);
        OGClubRaffle.Entry memory entry = raffle.getEntry(id, 0, 2);
        assertEq(entry.first, 500);
        assertEq(entry.end, 900);
        assertEq(raffle.ticketsOf(id, 0, alice), 700);
        assertEq(raffle.ticketsOf(id, 1, alice), 200);
    }

    function test_InvalidConfigurationPoolsLinesAndTickets() public {
        vm.expectRevert(OGClubRaffle.InvalidWindow.selector);
        raffle.createRaffle(block.timestamp, block.timestamp, pools(1));
        vm.expectRevert(OGClubRaffle.InvalidPools.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, new OGClubRaffle.PoolInput[](0));
        vm.expectRevert(OGClubRaffle.InvalidPools.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, new OGClubRaffle.PoolInput[](33));
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].ticketPrice = 0;
        vm.expectRevert(OGClubRaffle.InvalidPools.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
        input = pools(0);
        vm.expectRevert(OGClubRaffle.InvalidPrize.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
        input = pools(uint256(type(uint48).max) + 1);
        vm.expectRevert(OGClubRaffle.InvalidPrize.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
        input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](129);
        vm.expectRevert(OGClubRaffle.InvalidPools.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
        uint256 id = create(1);
        vm.expectRevert(OGClubRaffle.InvalidTickets.selector);
        enter(id, alice, 0);
        vm.expectRevert(OGClubRaffle.InvalidTickets.selector);
        enter(id, alice, uint256(type(uint48).max) + 1);
        vm.expectRevert(OGClubRaffle.InvalidPool.selector);
        raffle.enter(id, 1, 1);
        vm.expectRevert(OGClubRaffle.InvalidRaffle.selector);
        raffle.commitDraw(0);
    }

    function test_Maximum32PoolsAnd128PrizeLines() public {
        OGClubRaffle.PoolInput[] memory input = new OGClubRaffle.PoolInput[](32);
        for (uint256 i; i < 32; ++i) {
            input[i] = pools(1)[0];
            input[i].prizes = new OGClubRaffle.Prize[](4);
            for (uint256 j; j < 4; ++j) {
                input[i].prizes[j] = OGClubRaffle.Prize(j, 1);
            }
        }
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
        (,,, uint8 count,,,) = raffle.raffles(id);
        assertEq(count, 32);
        input[31].prizes = new OGClubRaffle.Prize[](5);
        vm.expectRevert(OGClubRaffle.InvalidPools.selector);
        raffle.createRaffle(block.timestamp, block.timestamp + 1, input);
    }

    function test_EntryFailureRollsBackRangesCapsAndPoints() public {
        uint256 id = create(1);
        staking.revokeSpender(address(raffle));
        vm.expectRevert(OGClubStaking.NotSpender.selector);
        enter(id, alice, 1);
        assertEq(raffle.ticketsOf(id, 0, alice), 0);
        (,,, uint256 sold,, uint256 entries) = raffle.getPool(id, 0);
        assertEq(sold, 0);
        assertEq(entries, 0);
        staking.grantSpender(address(raffle));
        vm.warp(block.timestamp + 7 days);
        staking.activateSpender(address(raffle));
        id = create(1);
        vm.expectRevert(OGClubStaking.InsufficientPoints.selector);
        enter(id, stranger, 1);
        (,,, sold,, entries) = raffle.getPool(id, 0);
        assertEq(sold, 0);
        assertEq(entries, 0);
    }

    function test_DrawHeaderAndTargetExactBoundaries() public {
        uint256 id = create(1);
        vm.expectRevert(OGClubRaffle.RaffleStillOpen.selector);
        raffle.commitDraw(id);
        vm.expectRevert(OGClubRaffle.TargetUnavailable.selector);
        raffle.draw(id, "");
        closeAndCommit(id);
        uint256 number = target(id);
        bytes32 seed = keccak256("seed");
        bytes memory header = HeaderBuilder.header(number, seed, 9);
        vm.roll(number);
        vm.expectRevert(OGClubRaffle.TargetUnavailable.selector);
        raffle.draw(id, header);
        vm.roll(number + 1);
        vm.expectRevert(OGClubRaffle.InvalidHeader.selector);
        raffle.draw(id, header);
        vm.setBlockhash(number, keccak256(header));
        vm.expectRevert(OGClubRaffle.InvalidHeader.selector);
        raffle.draw(id, HeaderBuilder.header(number, bytes32(0), 9));
        vm.roll(number + 256);
        vm.expectRevert(OGClubRaffle.TargetStillLive.selector);
        raffle.commitDraw(id);
        raffle.draw(id, header);
        (,,,,, bool drawn, bytes32 result) = raffle.raffles(id);
        assertTrue(drawn);
        assertEq(result, seed);
        vm.expectRevert(OGClubRaffle.AlreadyDrawn.selector);
        raffle.draw(id, header);
        vm.expectRevert(OGClubRaffle.AlreadyDrawn.selector);
        raffle.commitDraw(id);
    }

    function test_WrongNumberInAuthenticatedHeaderRejected() public {
        uint256 id = create(1);
        closeAndCommit(id);
        bytes memory header = HeaderBuilder.header(target(id) + 1, keccak256("seed"), 9);
        vm.roll(target(id) + 1);
        vm.setBlockhash(target(id), keccak256(header));
        vm.expectRevert(OGClubRaffle.InvalidHeader.selector);
        raffle.draw(id, header);
    }

    function test_RetargetOnlyAt257AndOldHeaderCannotDrawNewTarget() public {
        uint256 id = create(1);
        closeAndCommit(id);
        uint256 old = target(id);
        bytes memory oldHeader = HeaderBuilder.header(old, keccak256("old"), 9);
        vm.roll(old + 256);
        vm.setBlockhash(old, keccak256(oldHeader));
        vm.expectRevert(OGClubRaffle.TargetStillLive.selector);
        raffle.commitDraw(id);
        vm.roll(old + 257);
        vm.expectRevert(OGClubRaffle.TargetUnavailable.selector);
        raffle.draw(id, oldHeader);
        vm.prank(stranger);
        raffle.commitDraw(id);
        assertEq(target(id), old + 257 + 3);
        vm.roll(target(id) + 1);
        bytes memory header = HeaderBuilder.header(target(id), bytes32(0), 9);
        vm.setBlockhash(target(id), keccak256(header));
        vm.expectRevert(OGClubRaffle.InvalidHeader.selector);
        raffle.draw(id, oldHeader);
        raffle.draw(id, header); // A zero prevRandao is still a valid authenticated seed.
        (,,,,, bool drawn, bytes32 seed) = raffle.raffles(id);
        assertTrue(drawn);
        assertEq(seed, bytes32(0));
    }

    function testFuzz_ExactlyMinPrizesAndTicketsWinWithNoDuplicateTicket(
        uint8 rawTickets,
        uint8 rawPrizes,
        bytes32 seed
    ) public {
        uint256 tickets = bound(rawTickets, 0, 80);
        uint256 prizes = bound(rawPrizes, 1, 80);
        uint256 id = create(prizes);
        if (tickets != 0) enter(id, alice, tickets);
        draw(id, seed);
        uint256 count = tickets < prizes ? tickets : prizes;
        assertEq(raffle.winnerCount(id, 0), count);
        bool[] memory used = new bool[](tickets);
        for (uint256 k; k < count; ++k) {
            uint256 ticket = raffle.winningTicket(id, 0, k);
            assertLt(ticket, tickets);
            assertFalse(used[ticket]);
            used[ticket] = true;
        }
        vm.expectRevert(OGClubRaffle.InvalidWin.selector);
        raffle.winningTicket(id, 0, count);
        vm.expectRevert(OGClubRaffle.InvalidWin.selector);
        raffle.prizeOf(id, 0, count);
        if (count != 0) raffle.claim(id, 0, wins(id, 0));
        assertEq(furniture.totalSupply(), count);
    }

    function test_MultiItemPoolMintsExactQuantitiesIncludingDuplicateAndZeroIds() public {
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](4);
        input[0].prizes[0] = OGClubRaffle.Prize(0, 3);
        input[0].prizes[1] = OGClubRaffle.Prize(7, 5);
        input[0].prizes[2] = OGClubRaffle.Prize(9, 2);
        input[0].prizes[3] = OGClubRaffle.Prize(7, 4);
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1 days, input);
        enter(id, alice, 5);
        enter(id, bob, 15);
        draw(id, keccak256("multi-item"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        assertEq(all.length, 14);
        vm.prank(stranger);
        raffle.claim(id, 0, all);
        assertEq(furniture.totalSupply(0), 3);
        assertEq(furniture.totalSupply(7), 9);
        assertEq(furniture.totalSupply(9), 2);
        assertEq(furniture.totalSupply(), 14);
        for (uint256 k; k < all.length; ++k) {
            assertTrue(raffle.isClaimed(id, 0, k));
        }
    }

    function test_UnsoldPrizesAreRandomPositionsNotAlwaysTheTail() public {
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](20);
        for (uint256 i; i < 20; ++i) {
            input[0].prizes[i] = OGClubRaffle.Prize(i, 1);
        }
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1 days, input);
        enter(id, alice, 10);
        draw(id, keccak256("random prizes"));
        bool[20] memory used;
        bool beyondPrefix;
        for (uint256 k; k < 10; ++k) {
            uint256 item = raffle.prizeOf(id, 0, k);
            assertLt(item, 20);
            assertFalse(used[item]);
            used[item] = true;
            if (item >= 10) beyondPrefix = true;
        }
        assertTrue(beyondPrefix);
        raffle.claim(id, 0, wins(id, 0));
        for (uint256 i; i < 20; ++i) {
            assertEq(furniture.totalSupply(i), used[i] ? 1 : 0);
        }
    }

    function test_WrongKEntryAndDoubleClaimsRevertAtomically() public {
        uint256 id = create(2);
        enter(id, alice, 1);
        enter(id, bob, 1);
        vm.expectRevert(OGClubRaffle.NotDrawn.selector);
        raffle.winningTicket(id, 0, 0);
        draw(id, keccak256("claims"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        OGClubRaffle.Win[] memory one = new OGClubRaffle.Win[](1);
        one[0] = OGClubRaffle.Win(2, 0);
        vm.expectRevert(OGClubRaffle.InvalidWin.selector);
        raffle.claim(id, 0, one);
        one[0] = OGClubRaffle.Win(0, all[0].entry ^ 1);
        vm.expectRevert(OGClubRaffle.InvalidEntry.selector);
        raffle.claim(id, 0, one);
        one[0].entry = 2;
        vm.expectRevert(OGClubRaffle.InvalidEntry.selector);
        raffle.claim(id, 0, one);
        one[0] = all[0];
        vm.prank(stranger);
        raffle.claim(id, 0, one);
        vm.expectRevert(OGClubRaffle.AlreadyClaimed.selector);
        raffle.claim(id, 0, one);
        vm.expectRevert(OGClubRaffle.AlreadyClaimed.selector);
        raffle.claim(id, 0, all);
        assertEq(furniture.totalSupply(), 1);
        one[0] = all[1];
        raffle.claim(id, 0, one);
        assertEq(furniture.totalSupply(), 2);
    }

    function test_DuplicateWithinBatchRollsBackEverythingAndBitmapCrossesWords() public {
        uint256 id = create(300);
        enter(id, alice, 300);
        draw(id, keccak256("bitmap"));
        OGClubRaffle.Win[] memory list = new OGClubRaffle.Win[](2);
        list[0] = OGClubRaffle.Win(256, 0);
        list[1] = OGClubRaffle.Win(256, 0);
        vm.expectRevert(OGClubRaffle.AlreadyClaimed.selector);
        raffle.claim(id, 0, list);
        assertFalse(raffle.isClaimed(id, 0, 256));
        assertEq(furniture.totalSupply(), 0);
        list[0].k = 255;
        raffle.claim(id, 0, list);
        assertTrue(raffle.isClaimed(id, 0, 255));
        assertTrue(raffle.isClaimed(id, 0, 256));
        assertFalse(raffle.isClaimed(id, 0, 254));
    }

    function test_ContractWalletCanRedirectButNobodyElseCan() public {
        ClaimWallet wallet = new ClaimWallet();
        wallet.configure(address(0), "", true);
        fundPoints(address(wallet), 10 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 id = create(2);
        enter(id, address(wallet), 2);
        draw(id, keccak256("redirect"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        vm.expectRevert("receiver rejects");
        raffle.claim(id, 0, all);
        assertFalse(raffle.isClaimed(id, 0, 0));
        assertEq(furniture.totalSupply(), 0);
        vm.expectRevert(OGClubRaffle.NotEntryWallet.selector);
        raffle.claimTo(id, 0, all, alice);
        vm.prank(address(wallet));
        vm.expectRevert(OGClubRaffle.InvalidAddress.selector);
        raffle.claimTo(id, 0, all, address(0));
        wallet.execute(address(raffle), abi.encodeCall(raffle.claimTo, (id, 0, all, alice)));
        assertEq(furniture.balanceOf(alice, 7), 2);
    }

    function test_RevokedMinterClaimIsRetryableAndDoesNotReroll() public {
        uint256 id = create(1);
        enter(id, alice, 1);
        draw(id, keccak256("revoke"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        uint256 item = raffle.prizeOf(id, 0, 0);
        furniture.revokeMinter(address(raffle));
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(raffle)));
        raffle.claim(id, 0, all);
        assertFalse(raffle.isClaimed(id, 0, 0));
        furniture.grantMinter(address(raffle));
        vm.warp(block.timestamp + 7 days);
        furniture.activateMinter(address(raffle));
        vm.roll(block.number + 1000);
        vm.prank(stranger);
        raffle.claim(id, 0, all);
        assertEq(furniture.balanceOf(alice, item), 1);
    }

    function test_ReceiverCannotReenterEitherClaimPath() public {
        ClaimWallet wallet = new ClaimWallet();
        fundPoints(address(wallet), 10 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 id = create(2);
        enter(id, address(wallet), 2);
        draw(id, keccak256("reentry"));
        OGClubRaffle.Win[] memory one = new OGClubRaffle.Win[](1);
        one[0] = OGClubRaffle.Win(0, 0);
        OGClubRaffle.Win[] memory other = new OGClubRaffle.Win[](1);
        other[0] = OGClubRaffle.Win(1, 0);
        wallet.configure(address(raffle), abi.encodeCall(raffle.claim, (id, 0, other)), false);
        raffle.claim(id, 0, one);
        assertFalse(wallet.callbackSucceeded());
        assertFalse(raffle.isClaimed(id, 0, 1));
        wallet.configure(address(raffle), abi.encodeCall(raffle.claimTo, (id, 0, other, alice)), false);
        raffle.claim(id, 0, other);
        assertFalse(wallet.callbackSucceeded());
        assertEq(furniture.balanceOf(address(wallet), 7), 2);
    }

    function test_OwnerCannotModifyTermsPauseOrCancelStartedRaffle() public {
        uint256 id = create(1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        raffle.createRaffle(block.timestamp, block.timestamp + 1 days, pools(1));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        raffle.cancelRaffle(id);
        vm.expectRevert(OGClubRaffle.AlreadyStarted.selector);
        raffle.cancelRaffle(id);
        (bool ok,) = address(raffle).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok);
        (ok,) = address(raffle).call(abi.encodeWithSignature("setRaffleNotice(uint256)", 0));
        assertFalse(ok);
        (ok,) = address(raffle).call(abi.encodeWithSignature("setTicketPrice(uint256,uint256,uint256)", id, 0, 0));
        assertFalse(ok);
        raffle.transferOwnership(alice);
        vm.prank(alice);
        raffle.acceptOwnership();
        (, uint256 price,,,,) = raffle.getPool(id, 0);
        assertEq(price, 1 ether);
    }

    function test_ClaimToCannotRedirectAnotherWalletInTheSameBatch() public {
        uint256 id = create(2);
        enter(id, alice, 1);
        enter(id, bob, 1);
        draw(id, keccak256("mixed-wallet"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        address firstWallet = raffle.getEntry(id, 0, all[0].entry).wallet;
        vm.prank(firstWallet);
        vm.expectRevert(OGClubRaffle.NotEntryWallet.selector);
        raffle.claimTo(id, 0, all, stranger);
        assertFalse(raffle.isClaimed(id, 0, 0));
        assertEq(furniture.totalSupply(), 0);
        raffle.claim(id, 0, all);
        assertEq(furniture.balanceOf(alice, 7), 1);
        assertEq(furniture.balanceOf(bob, 7), 1);
    }

    function test_RejectingWalletDoesNotBlockOtherWinnersAndEmptyClaimRejected() public {
        ClaimWallet wallet = new ClaimWallet();
        wallet.configure(address(0), "", true);
        fundPoints(address(wallet), 1 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 id = create(2);
        enter(id, address(wallet), 1);
        enter(id, alice, 1);
        draw(id, keccak256("isolated-wallet"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        vm.expectRevert("receiver rejects");
        raffle.claim(id, 0, all);
        OGClubRaffle.Win[] memory good = new OGClubRaffle.Win[](1);
        good[0] = all[all[0].entry == 1 ? 0 : 1];
        raffle.claim(id, 0, good);
        assertEq(furniture.balanceOf(alice, 7), 1);
        vm.expectRevert(OGClubRaffle.EmptyClaim.selector);
        raffle.claim(id, 0, new OGClubRaffle.Win[](0));
    }

    function test_HugeTicketAndPrizeCountsDoNotRequireIterationToDrawOrClaim() public {
        uint256 tickets = type(uint48).max;
        fundPoints(alice, tickets * 1 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 id = create(tickets);
        enter(id, alice, tickets);
        vm.expectRevert(OGClubRaffle.InvalidTickets.selector);
        enter(id, bob, 1);
        draw(id, keccak256("large domain"));
        OGClubRaffle.Win[] memory one = new OGClubRaffle.Win[](1);
        one[0] = OGClubRaffle.Win(tickets - 1, 0);
        raffle.claim(id, 0, one);
        assertEq(furniture.balanceOf(alice, 7), 1);
        assertTrue(raffle.isClaimed(id, 0, tickets - 1));
    }

    function test_TicketPriceMultiplicationOverflowDoesNotSpendOrRecordEntry() public {
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].ticketPrice = type(uint256).max;
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1 days, input);
        uint256 points = staking.pointsOf(alice);
        vm.expectRevert();
        enter(id, alice, 2);
        assertEq(staking.pointsOf(alice), points);
        (,,, uint256 sold,, uint256 entries) = raffle.getPool(id, 0);
        assertEq(sold, 0);
        assertEq(entries, 0);
    }
}
