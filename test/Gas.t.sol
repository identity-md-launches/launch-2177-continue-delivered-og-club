// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RaffleTestBase} from "./helpers/RaffleTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @dev Run with --isolate. Measure the target call, count durable fresh slots across every callee,
///      and reprice only storage creation per EIP-8037: 64 * 1530 instead of 20,000 gas per slot.
contract GasTest is RaffleTestBase {
    function setUp() public override {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 1e18);
        raffle = new OGClubRaffle(staking, furniture, address(this), 0);
        furniture.grantMinter(address(raffle));
        staking.grantSpender(address(raffle));
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
    }

    function report(string memory label, uint256 gasUsed, uint256 expectedNewSlots) internal {
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 count;
        uint256 length;
        for (uint256 i; i < accesses.length; ++i) {
            length += accesses[i].storageAccesses.length;
        }
        bytes32[] memory seen = new bytes32[](length);
        uint256 used;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                if (!access.isWrite || access.reverted) continue;
                bytes32 key = keccak256(abi.encode(access.account, access.slot));
                bool duplicate;
                for (uint256 k; k < used; ++k) {
                    if (seen[k] == key) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                seen[used++] = key;
                if (access.previousValue == bytes32(0) && vm.load(access.account, access.slot) != bytes32(0)) ++count;
            }
        }
        emit log_string(label);
        emit log_named_uint("Cancun call gas", gasUsed);
        emit log_named_uint("New persistent slots", count);
        emit log_named_uint("EIP-8037 state gas", count * 97_920);
        emit log_named_uint("EIP-8037 storage-repriced call gas", gasUsed + count * 77_920);
        assertEq(count, expectedNewSlots, "gas table new-slot assumption changed");
    }

    function test_GasFirstStake() public {
        vm.startStateDiffRecording();
        vm.prank(alice);
        staking.stake(100 ether);
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        report("First-ever stake / fresh staker", gasUsed, 3);
    }

    function test_GasUnstake() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(block.timestamp + 1 days);
        vm.startStateDiffRecording();
        vm.prank(alice);
        staking.unstake(10 ether);
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        report("Partial unstake / first fee / first checkpoint", gasUsed, 2);
    }

    function test_GasEnter() public {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 id = create(10);
        vm.startStateDiffRecording();
        vm.prank(alice);
        raffle.enter(id, 0, 10);
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        report("First entry / ten tickets / first points checkpoint", gasUsed, 4);
    }

    function test_GasDraw() public {
        uint256 id = create(10);
        closeAndCommit(id);
        bytes memory header = HeaderBuilder.header(target(id), keccak256("gas draw"), 9);
        vm.roll(target(id) + 1);
        vm.setBlockhash(target(id), keccak256(header));
        vm.startStateDiffRecording();
        raffle.draw(id, header);
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        report("Draw / 23-field synthetic header", gasUsed, 1);
    }

    function measureClaim(uint256 count) internal {
        vm.prank(alice);
        staking.stake(100 ether);
        vm.warp(block.timestamp + 1 days);
        OGClubRaffle.PoolInput[] memory input = pools(1);
        input[0].prizes = new OGClubRaffle.Prize[](count);
        for (uint256 i; i < count; ++i) {
            input[0].prizes[i] = OGClubRaffle.Prize(i + 1, 1);
        }
        uint256 id = raffle.createRaffle(block.timestamp, block.timestamp + 1 days, input);
        enter(id, alice, count);
        draw(id, keccak256("claim gas"));
        OGClubRaffle.Win[] memory all = wins(id, 0);
        vm.startStateDiffRecording();
        raffle.claim(id, 0, all);
        uint256 gasUsed = vm.lastCallGas().gasTotalUsed;
        report(
            count == 1 ? "Claim one win / fresh furniture wallet" : "Claim ten distinct items / fresh furniture wallet",
            gasUsed,
            2 * count + 2
        );
    }

    function test_GasClaimOne() public {
        measureClaim(1);
    }

    function test_GasClaimTen() public {
        measureClaim(10);
    }
}
