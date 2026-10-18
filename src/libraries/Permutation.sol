// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Keyed, eight-round balanced Feistel permutation with cycle walking onto [0, size).
/// @dev No table or iteration over entrants. The enclosing power-of-four domain is less than 4*size.
///      Keccak round functions give a pseudorandom permutation, not verifiable external entropy.
library Permutation {
    error InvalidPermutationInput();

    function permute(uint256 index, uint256 size, bytes32 key) internal pure returns (uint256) {
        if (size == 0 || size > type(uint48).max || index >= size) revert InvalidPermutationInput();
        if (size == 1) return 0;
        uint256 halfBits;
        uint256 domain = 1;
        while (domain < size) {
            domain <<= 2;
            ++halfBits;
        }
        uint256 mask = (uint256(1) << halfBits) - 1;
        do {
            uint256 left = index >> halfBits;
            uint256 right = index & mask;
            for (uint256 round; round < 8; ++round) {
                (left, right) = (right, left ^ (uint256(keccak256(abi.encode(key, round, right))) & mask));
            }
            index = (left << halfBits) | right;
        } while (index >= size);
        return index;
    }
}
