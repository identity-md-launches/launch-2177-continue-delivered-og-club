// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockOG} from "../../src/mocks/MockOG.sol";
import {OGClubFurniture} from "../../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../../src/OGClubFarmVault.sol";
import {OGClubStaking} from "../../src/OGClubStaking.sol";
import {OGClubRaffle} from "../../src/OGClubRaffle.sol";
import {HeaderBuilder} from "./HeaderBuilder.sol";

abstract contract RaffleTestBase is Test {
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubStaking internal staking;
    OGClubRaffle internal raffle;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 1e18);
        raffle = new OGClubRaffle(staking, furniture, address(this), 0);
        furniture.grantMinter(address(raffle));
        staking.grantSpender(address(raffle));
        fundPoints(alice, 1000 ether);
        fundPoints(bob, 1000 ether);
        vm.warp(block.timestamp + 1 days);
    }

    function fundPoints(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function pools(uint256 quantity) internal pure returns (OGClubRaffle.PoolInput[] memory inputs) {
        inputs = new OGClubRaffle.PoolInput[](1);
        OGClubRaffle.Prize[] memory prizes = new OGClubRaffle.Prize[](1);
        prizes[0] = OGClubRaffle.Prize(7, quantity);
        inputs[0] = OGClubRaffle.PoolInput(3, 1 ether, 0, prizes);
    }

    function create(uint256 quantity) internal returns (uint256) {
        return raffle.createRaffle(block.timestamp, block.timestamp + 1 days, pools(quantity));
    }

    function enter(uint256 id, address who, uint256 tickets) internal returns (uint256 entry) {
        vm.prank(who);
        return raffle.enter(id, 0, tickets);
    }

    function target(uint256 id) internal view returns (uint256 value) {
        (,, uint64 targetBlock,,,,) = raffle.raffles(id);
        return targetBlock;
    }

    function closeAndCommit(uint256 id) internal {
        (, uint64 closesAt,,,,,) = raffle.raffles(id);
        vm.warp(closesAt);
        vm.prank(stranger);
        raffle.commitDraw(id);
    }

    function draw(uint256 id, bytes32 seed) internal {
        closeAndCommit(id);
        uint256 number = target(id);
        bytes memory header = HeaderBuilder.header(number, seed, 9);
        vm.roll(number + 1);
        vm.setBlockhash(number, keccak256(header));
        vm.prank(stranger);
        raffle.draw(id, header);
    }

    function wins(uint256 id, uint256 pool) internal view returns (OGClubRaffle.Win[] memory result) {
        uint256 count = raffle.winnerCount(id, pool);
        result = new OGClubRaffle.Win[](count);
        (,,,,, uint256 entries) = raffle.getPool(id, pool);
        for (uint256 k; k < count; ++k) {
            uint256 ticket = raffle.winningTicket(id, pool, k);
            for (uint256 i; i < entries; ++i) {
                OGClubRaffle.Entry memory entry = raffle.getEntry(id, pool, i);
                if (ticket >= entry.first && ticket < entry.end) {
                    result[k] = OGClubRaffle.Win(k, i);
                    break;
                }
            }
        }
    }
}
