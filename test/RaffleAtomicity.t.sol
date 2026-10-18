// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RaffleTestBase} from "./helpers/RaffleTestBase.sol";
import {OGClubRaffle} from "src/OGClubRaffle.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract LateRejectingWinner is ERC1155Holder {
    error DeliveryRejected();

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure override returns (bytes4) {
        revert DeliveryRejected();
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert DeliveryRejected();
    }
}

contract RaffleAtomicityTest is RaffleTestBase {
    function test_LateInvalidEntryRollsBackAnEarlierWalletMint() public {
        uint256 id = create(2);
        enter(id, alice, 1);
        enter(id, bob, 1);
        draw(id, keccak256("late-invalid-entry"));
        OGClubRaffle.Win[] memory list = wins(id, 0);
        uint256 savedEntry = list[1].entry;
        list[1].entry = 2;
        vm.expectRevert(OGClubRaffle.InvalidEntry.selector);
        raffle.claim(id, 0, list);
        assertEq(furniture.totalSupply(), 0);
        assertEq(furniture.balanceOf(alice, 7), 0);
        assertEq(furniture.balanceOf(bob, 7), 0);
        assertFalse(raffle.isClaimed(id, 0, 0));
        assertFalse(raffle.isClaimed(id, 0, 1));
        list[1].entry = savedEntry;
        vm.prank(stranger);
        raffle.claim(id, 0, list);
        assertEq(furniture.balanceOf(alice, 7), 1);
        assertEq(furniture.balanceOf(bob, 7), 1);
    }

    function test_LateReceiverRejectionRollsBackPreviouslyMintedWalletGroup() public {
        LateRejectingWinner rejector = new LateRejectingWinner();
        fundPoints(address(rejector), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 id = create(3);
        enter(id, alice, 1);
        enter(id, bob, 1);
        enter(id, address(rejector), 1);
        draw(id, keccak256("reject-last"));
        OGClubRaffle.Win[] memory unordered = wins(id, 0);
        OGClubRaffle.Win[] memory ordered = new OGClubRaffle.Win[](3);
        // Force two successful, distinct recipient groups before the rejecting group.
        for (uint256 k; k < 3; ++k) {
            ordered[unordered[k].entry] = unordered[k];
        }
        vm.expectRevert(LateRejectingWinner.DeliveryRejected.selector);
        raffle.claim(id, 0, ordered);
        assertEq(furniture.totalSupply(), 0);
        for (uint256 k; k < 3; ++k) {
            assertFalse(raffle.isClaimed(id, 0, k));
        }

        OGClubRaffle.Win[] memory good = new OGClubRaffle.Win[](2);
        good[0] = ordered[0];
        good[1] = ordered[1];
        raffle.claim(id, 0, good);
        assertEq(furniture.balanceOf(alice, 7), 1);
        assertEq(furniture.balanceOf(bob, 7), 1);
        assertFalse(raffle.isClaimed(id, 0, ordered[2].k));
        OGClubRaffle.Win[] memory rescued = new OGClubRaffle.Win[](1);
        rescued[0] = ordered[2];
        vm.prank(address(rejector));
        raffle.claimTo(id, 0, rescued, stranger);
        assertEq(furniture.balanceOf(stranger, 7), 1);
        assertEq(furniture.totalSupply(), 3);
    }

    function test_LateInvalidPoolCreationDoesNotLeaveRaffleOrPrizeStorage() public {
        OGClubRaffle.PoolInput[] memory input = new OGClubRaffle.PoolInput[](2);
        input[0] = pools(10)[0];
        input[1] = pools(1)[0];
        input[1].prizes[0].quantity = 0;
        vm.expectRevert(OGClubRaffle.InvalidPrize.selector);
        raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        assertEq(raffle.raffleCount(), 0);
        vm.expectRevert(OGClubRaffle.InvalidRaffle.selector);
        raffle.getPool(1, 0);
        uint256 id = create(2);
        assertEq(id, 1);
        OGClubRaffle.PrizeLine[] memory stored = raffle.getPrizes(id, 0);
        assertEq(stored.length, 1);
        assertEq(stored[0].end, 2);
        (,,,, uint256 prizes, uint256 entries) = raffle.getPool(id, 0);
        assertEq(prizes, 2);
        assertEq(entries, 0);
    }

    function test_PrizeLimitAppliesToSumAcrossLinesAndRollbackAllowsReuse() public {
        uint256 maximum = type(uint48).max;
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](2);
        input[0].prizes[0] = OGClubRaffle.Prize(7, maximum - 1);
        input[0].prizes[1] = OGClubRaffle.Prize(9, 2);
        vm.expectRevert(OGClubRaffle.InvalidPrize.selector);
        raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        assertEq(raffle.raffleCount(), 0);
        input[0].prizes[1].quantity = 1;
        uint256 id = raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        OGClubRaffle.PrizeLine[] memory stored = raffle.getPrizes(id, 0);
        assertEq(stored.length, 2);
        assertEq(stored[0].end, maximum - 1);
        assertEq(stored[1].end, maximum);
        (,,,, uint256 prizes,) = raffle.getPool(id, 0);
        assertEq(prizes, maximum);
    }

    function test_ClaimBitmapIsIndependentAcrossRafflesAndPools() public {
        OGClubRaffle.PoolInput[] memory input = new OGClubRaffle.PoolInput[](2);
        input[0] = pools(1)[0];
        input[1] = pools(1)[0];
        input[1].prizes[0].itemId = 9;
        uint256 first = raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        uint256 second = raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        for (uint256 id = first; id <= second; ++id) {
            vm.startPrank(alice);
            raffle.enter(id, 0, 1);
            raffle.enter(id, 1, 1);
            vm.stopPrank();
        }
        draw(first, keccak256("first draw"));
        draw(second, keccak256("second draw"));
        OGClubRaffle.Win[] memory one = new OGClubRaffle.Win[](1);
        one[0] = OGClubRaffle.Win(0, 0);
        raffle.claim(first, 0, one);
        assertFalse(raffle.isClaimed(first, 1, 0));
        assertFalse(raffle.isClaimed(second, 0, 0));
        assertFalse(raffle.isClaimed(second, 1, 0));
        raffle.claim(first, 1, one);
        raffle.claim(second, 0, one);
        raffle.claim(second, 1, one);
        assertEq(furniture.balanceOf(alice, 7), 2);
        assertEq(furniture.balanceOf(alice, 9), 2);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_MultiItemClaimsCanBeShuffledAndFragmented(uint8[4] memory raw, bytes32 seed) public {
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](4);
        uint256 quantity;
        for (uint256 j; j < 4; ++j) {
            uint256 amount = bound(raw[j], 1, 6);
            input[0].prizes[j] = OGClubRaffle.Prize(j % 3, amount); // Two separate lines for item 0.
            quantity += amount;
        }
        uint256 id = raffle.createRaffle(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days, input);
        // Alternate wallets in several ranges. Every expanded prize position will be awarded.
        for (uint256 i; i < 6; ++i) {
            enter(id, i % 2 == 0 ? alice : bob, 4);
        }
        draw(id, seed);
        OGClubRaffle.Win[] memory list = wins(id, 0);
        assertEq(list.length, quantity);
        for (uint256 i = list.length; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (list[i - 1], list[j]) = (list[j], list[i - 1]);
        }
        uint256[3] memory expectedAlice;
        uint256[3] memory expectedBob;
        for (uint256 i; i < list.length; ++i) {
            uint256 itemId = raffle.prizeOf(id, 0, list[i].k);
            // Wallets follow the independently constructed entry ordering.
            if (list[i].entry % 2 == 0) ++expectedAlice[itemId];
            else ++expectedBob[itemId];
        }
        uint256 cursor;
        while (cursor < list.length) {
            uint256 length = 1 + uint256(keccak256(abi.encode(seed, cursor))) % 5;
            if (length > list.length - cursor) length = list.length - cursor;
            OGClubRaffle.Win[] memory batch = new OGClubRaffle.Win[](length);
            for (uint256 i; i < length; ++i) {
                batch[i] = list[cursor + i];
            }
            vm.prank(stranger);
            raffle.claim(id, 0, batch);
            cursor += length;
            assertEq(furniture.totalSupply(), cursor);
        }
        for (uint256 j; j < 3; ++j) {
            uint256 expected = input[0].prizes[j].quantity;
            if (j == 0) expected += input[0].prizes[3].quantity;
            assertEq(furniture.totalSupply(j), expected);
            assertEq(furniture.balanceOf(alice, j), expectedAlice[j]);
            assertEq(furniture.balanceOf(bob, j), expectedBob[j]);
            assertEq(furniture.balanceOf(stranger, j), 0);
        }
        for (uint256 k; k < quantity; ++k) {
            assertTrue(raffle.isClaimed(id, 0, k));
        }
    }
}
