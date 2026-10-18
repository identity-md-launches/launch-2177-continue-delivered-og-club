// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

contract VaultHandler is Test {
    OGClubFarmVault public vault;
    MockOG public token;

    struct Ghost {
        address account;
        uint256 amount;
        uint256 opensAt;
        bool closed;
        bool paid;
    }
    Ghost[] public seasons;
    uint256 public reserved;
    uint256 public funded;
    uint256 public paid;
    uint256 public lastProposal;
    uint256 public claims;
    uint256 public releases;
    uint256 public cancellations;

    constructor(OGClubFarmVault vault_, MockOG token_) {
        vault = vault_;
        token = token_;
    }

    function accept() external {
        vault.acceptOwnership();
    }

    function count() external view returns (uint256) {
        return seasons.length;
    }

    function fund(uint96 raw) external {
        uint256 amount = bound(raw, 1, 1000 ether);
        token.mint(address(vault), amount);
        funded += amount;
    }

    function propose(uint96 raw, uint8 who) external {
        if (seasons.length != 0 && block.timestamp < lastProposal + 7 days) return;
        uint256 max = (funded - paid - reserved) / 2;
        if (max == 0) return;
        uint256 amount = bound(raw, 1, max);
        address account = address(uint160(uint256(keccak256(abi.encode("farmer", who))) >> 96));
        if (account == address(0) || account == address(vault)) return;
        uint256 id = seasons.length + 1;
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(id, account, amount))));
        assertEq(vault.proposeSeason(root, amount), id);
        seasons.push(Ghost(account, amount, block.timestamp + 3 days, false, false));
        lastProposal = block.timestamp;
        reserved += amount;
    }

    function claim(uint8 raw) external {
        if (seasons.length == 0) return;
        uint256 i = raw % seasons.length;
        Ghost storage season = seasons[i];
        if (
            season.closed || season.paid || block.timestamp < season.opensAt
                || block.timestamp >= season.opensAt + 90 days
        ) return;
        vault.claim(i + 1, season.account, season.amount, new bytes32[](0));
        season.paid = true;
        paid += season.amount;
        reserved -= season.amount;
        ++claims;
    }

    function cancel(uint8 raw) external {
        if (seasons.length == 0) return;
        uint256 i = raw % seasons.length;
        Ghost storage season = seasons[i];
        if (season.closed || block.timestamp >= season.opensAt) return;
        vault.cancelSeason(i + 1);
        season.closed = true;
        reserved -= season.amount;
        ++cancellations;
    }

    function release(uint8 raw) external {
        if (seasons.length == 0) return;
        uint256 i = raw % seasons.length;
        Ghost storage season = seasons[i];
        if (season.closed || block.timestamp < season.opensAt + 90 days) return;
        vault.releaseSeason(i + 1);
        season.closed = true;
        if (!season.paid) reserved -= season.amount;
        ++releases;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 100 days));
    }
}

contract VaultInvariantTest is Test {
    OGClubFarmVault internal vault;
    MockOG internal token;
    VaultHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new MockOG(address(this));
        vault = new OGClubFarmVault(token, address(this));
        handler = new VaultHandler(vault, token);
        vault.transferOwnership(address(handler));
        handler.accept();
        handler.fund(1000 ether);
        handler.propose(100 ether, 0);
        handler.cancel(0);
        handler.advance(7 days);
        handler.propose(100 ether, 1);
        handler.advance(3 days);
        handler.claim(1);
        handler.advance(4 days);
        handler.propose(100 ether, 2);
        handler.advance(93 days);
        handler.release(2);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.propose.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.release.selector;
        selectors[5] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_VaultAlwaysCoversReservationsAndOnlyClaimsMoveTokens() public view {
        assertGe(token.balanceOf(address(vault)), vault.reserved());
        assertEq(vault.reserved(), handler.reserved());
        assertEq(token.balanceOf(address(vault)) + handler.paid(), handler.funded());
        uint256 sum;
        for (uint256 i; i < handler.count(); ++i) {
            (address who, uint256 amount,, bool closed, bool paid) = handler.seasons(i);
            (, uint256 remaining,, bool actualClosed) = vault.seasons(i + 1);
            assertEq(actualClosed, closed);
            assertEq(vault.claimed(i + 1, who), paid);
            assertEq(remaining, closed || paid ? 0 : amount);
            sum += remaining;
        }
        assertEq(sum, vault.reserved());
        assertGt(handler.claims(), 0);
        assertGt(handler.releases(), 0);
        assertGt(handler.cancellations(), 0);
    }
}
