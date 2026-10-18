// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RaffleTestBase} from "./helpers/RaffleTestBase.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";
import {MainnetHeaders} from "./fixtures/MainnetHeaders.sol";
import {SepoliaHeader} from "./fixtures/SepoliaHeader.sol";
import {BlockHeader} from "../src/libraries/BlockHeader.sol";

contract HeaderHarness {
    function decode(bytes calldata header) external pure returns (uint256 number, bytes32 randao) {
        return BlockHeader.decode(header);
    }
}

contract BlockHeaderTest is RaffleTestBase {
    HeaderHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new HeaderHarness();
    }

    function checkHeader(bytes memory header, uint256 expectedNumber, bytes32 expectedHash, bytes32 expectedRandao)
        internal
    {
        assertEq(keccak256(header), expectedHash, "RLP must hash to the published block hash");
        (uint256 number, bytes32 randao) = harness.decode(header);
        assertEq(number, expectedNumber);
        assertEq(randao, expectedRandao, "decoded prevRandao must equal published mixHash");

        vm.roll(number - 3);
        uint256 id = create(10);
        enter(id, alice, 10);
        closeAndCommit(id);
        assertEq(target(id), number);
        vm.roll(number + 1);
        vm.setBlockhash(number, expectedHash);
        raffle.draw(id, header);
        (,,,,,, bytes32 seed) = raffle.raffles(id);
        assertEq(seed, randao);
    }

    function test_RealSepoliaHeaderWithAccessListHashAndSlotNumber() public {
        vm.chainId(11155111);
        (bytes memory header, uint256 number, bytes32 hash, bytes32 randao) = SepoliaHeader.fixture();
        checkHeader(header, number, hash, randao);
    }

    function test_RealMainnetShanghaiHeader() public {
        (bytes memory header, uint256 number, bytes32 hash, bytes32 randao) = MainnetHeaders.shanghai();
        checkHeader(header, number, hash, randao);
    }

    function test_RealMainnetCancunHeader() public {
        (bytes memory header, uint256 number, bytes32 hash, bytes32 randao) = MainnetHeaders.cancun();
        checkHeader(header, number, hash, randao);
    }

    function test_RealMainnetPragueHeader() public {
        (bytes memory header, uint256 number, bytes32 hash, bytes32 randao) = MainnetHeaders.prague();
        checkHeader(header, number, hash, randao);
    }

    function testFuzz_ArbitraryTrailingFieldCount(uint8 trailing, uint256 number, bytes32 randao) public view {
        trailing = uint8(bound(trailing, 0, 80));
        bytes memory header = HeaderBuilder.header(number, randao, trailing);
        (uint256 decodedNumber, bytes32 decodedRandao) = harness.decode(header);
        assertEq(decodedNumber, number);
        assertEq(decodedRandao, randao);
    }

    function test_ZeroNumberAndZeroMixHashAreValidRLP() public view {
        (uint256 number, bytes32 randao) = harness.decode(HeaderBuilder.header(0, bytes32(0), 0));
        assertEq(number, 0);
        assertEq(randao, bytes32(0));
    }

    function test_MalformedRLPBoundsAndCanonicalLengths() public {
        bytes[] memory invalid = new bytes[](11);
        invalid[0] = hex"";
        invalid[1] = hex"80"; // String, not list.
        invalid[2] = hex"01"; // Single byte, not list.
        invalid[3] = hex"f8"; // Missing length.
        invalid[4] = hex"f800"; // Leading zero length.
        invalid[5] = hex"f80180"; // Long length for short payload.
        invalid[6] = hex"ffFFFFFFFFFFFFFFFF"; // Impossible payload length.
        invalid[7] = hex"c28101"; // Noncanonical single-byte string.
        invalid[8] = hex"c2b838"; // String runs beyond the list.
        invalid[9] = hex"c1b8"; // Missing string length.
        invalid[10] = bytes.concat(HeaderBuilder.header(1, bytes32(0), 0), hex"00"); // Outside root list.
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(BlockHeader.InvalidRLP.selector);
            harness.decode(invalid[i]);
        }
    }

    function test_MissingFieldsAndInvalidNumberOrMixHash() public {
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(hex"c0");
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(new bytes[](13)));
        bytes[] memory fields = HeaderBuilder.fields(1, bytes32(0), 0);
        fields[8] = hex"00"; // Zero integers must be encoded as an empty string.
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(fields));
        fields[8] = hex"0001";
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(fields));
        fields[8] = new bytes(33);
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(fields));
        fields[8] = hex"01";
        fields[13] = new bytes(31);
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(fields));
        fields[13] = new bytes(33);
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        harness.decode(HeaderBuilder.list(fields));
    }

    function testFuzz_AnyMalformedInputRevertsWithCustomError(bytes calldata input) public {
        (bool success, bytes memory result) = address(harness).call(abi.encodeCall(harness.decode, (input)));
        if (!success) {
            assertEq(result.length, 4);
            bytes4 selector = bytes4(result);
            assertTrue(
                selector == BlockHeader.InvalidRLP.selector || selector == BlockHeader.InvalidHeaderFields.selector
            );
        }
    }

    function test_MalformedAuthenticatedHeaderCannotMint() public {
        uint256 id = create(1);
        closeAndCommit(id);
        vm.roll(target(id) + 1);
        vm.setBlockhash(target(id), keccak256(hex"c0"));
        vm.expectRevert(BlockHeader.InvalidHeaderFields.selector);
        raffle.draw(id, hex"c0");
        (,,,,, bool drawn,) = raffle.raffles(id);
        assertFalse(drawn);
        assertEq(furniture.totalSupply(), 0);
    }
}
