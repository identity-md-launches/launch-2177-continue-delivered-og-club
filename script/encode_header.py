#!/usr/bin/env python3
"""Encode an eth_getBlockByNumber JSON response as an execution-header RLP hex string.

Uses only Python's standard library. Read a JSON file argument or stdin. Supports
headers through the Sepolia block-access-list/slot-number extensions; never silently drops unknown new consensus header fields.
Compare the result's `cast keccak` with the block's published hash before drawing.
"""

import json
import sys

BASE_FIELDS = (
    "parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot",
    "receiptsRoot", "logsBloom", "difficulty", "number", "gasLimit", "gasUsed",
    "timestamp", "extraData", "mixHash", "nonce",
)
TRAILING_FIELDS = (
    "baseFeePerGas", "withdrawalsRoot", "blobGasUsed", "excessBlobGas",
    "parentBeaconBlockRoot", "requestsHash", "blockAccessListHash", "slotNumber",
)
QUANTITIES = {
    "difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas",
    "blobGasUsed", "excessBlobGas", "slotNumber",
}


def quantity(value):
    value = int(value, 16) if isinstance(value, str) else value
    if value < 0:
        raise ValueError("negative header quantity")
    return value.to_bytes((value.bit_length() + 7) // 8, "big")


def prefix(length, base):
    if length < 56:
        return bytes([base + length])
    size = quantity(length)
    return bytes([base + 55 + len(size)]) + size


def rlp_string(value):
    if len(value) == 1 and value[0] < 128:
        return value
    return prefix(len(value), 0x80) + value


def encode(block):
    if "result" in block:
        block = block["result"]
    if not isinstance(block, dict):
        raise ValueError("expected a JSON block object")
    keys = list(BASE_FIELDS)
    missing = False
    for key in TRAILING_FIELDS:
        if block.get(key) is None:
            missing = True
        else:
            if missing:
                raise ValueError("header has a gap before " + key)
            keys.append(key)
    # Only explicitly recognized RPC metadata may be omitted from the consensus header.
    metadata = {"hash", "size", "totalDifficulty", "transactions", "uncles", "withdrawals"}
    unknown = set(block) - set(BASE_FIELDS) - set(TRAILING_FIELDS) - metadata
    if unknown:
        raise ValueError("unsupported header fields: " + ", ".join(sorted(unknown)))
    fields = [
        quantity(block[key]) if key in QUANTITIES else bytes.fromhex(block[key].removeprefix("0x"))
        for key in keys
    ]
    payload = b"".join(rlp_string(field) for field in fields)
    return prefix(len(payload), 0xC0) + payload


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit("usage: python3 script/encode_header.py [block.json]")
    if len(sys.argv) == 2:
        with open(sys.argv[1], encoding="utf-8") as source:
            block = json.load(source)
    else:
        block = json.load(sys.stdin)
    print("0x" + encode(block).hex())
