// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {Permutation} from "../src/libraries/Permutation.sol";

contract PermutationHarness {
    function permute(uint256 index, uint256 size, bytes32 key) external pure returns (uint256) {
        return Permutation.permute(index, size, key);
    }
}

contract PermutationTest is Test {
    function testFuzz_SmallDomainsAreBijections(uint8 sizeSeed, bytes32 seed) public pure {
        uint256 size = bound(sizeSeed, 1, 200);
        bool[] memory seen = new bool[](size);
        for (uint256 i; i < size; ++i) {
            uint256 output = Permutation.permute(i, size, seed);
            assertLt(output, size);
            assertFalse(seen[output]);
            seen[output] = true;
            assertEq(Permutation.permute(i, size, seed), output);
        }
        for (uint256 i; i < size; ++i) {
            assertTrue(seen[i]);
        }
    }

    function testFuzz_LargeDomainsInRangeAndDistinct(uint48 rawSize, uint48 a, uint48 b, bytes32 key) public pure {
        uint256 size = bound(rawSize, 2, type(uint48).max);
        uint256 first = uint256(a) % size;
        uint256 second = uint256(b) % size;
        uint256 x = Permutation.permute(first, size, key);
        uint256 y = Permutation.permute(second, size, key);
        assertLt(x, size);
        assertLt(y, size);
        if (first != second) assertNotEq(x, y);
    }

    function test_InvalidDomainAndIndexRejected() public {
        PermutationHarness harness = new PermutationHarness();
        vm.expectRevert(Permutation.InvalidPermutationInput.selector);
        harness.permute(0, 0, bytes32(0));
        vm.expectRevert(Permutation.InvalidPermutationInput.selector);
        harness.permute(1, 1, bytes32(0));
        vm.expectRevert(Permutation.InvalidPermutationInput.selector);
        harness.permute(0, uint256(type(uint48).max) + 1, bytes32(0));
        assertEq(harness.permute(0, 1, bytes32(0)), 0);
    }
}
