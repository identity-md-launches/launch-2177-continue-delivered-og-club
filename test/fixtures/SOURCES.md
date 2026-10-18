# Execution header fixtures

These are real Ethereum execution blocks, not synthetic fork examples.
The JSON files contain the published header fields and block hash, with transaction
and withdrawal bodies omitted. Tests embed the RLP in `MainnetHeaders.sol`, so no
network, environment variables, FFI, or filesystem cheatcodes are needed.

| Fork represented | Mainnet block | Fields | Published mixHash / prevRandao |
| --- | ---: | ---: | --- |
| Shanghai | 17034870 | 17 | `0x812ed704cc408c435c7baa6e86296c1ac654a139ae8c4a26d6460742b951d4f9` |
| Cancun | 19426589 | 20 | `0x57dc6b69f4e021c07813699c031bf61baad4f468040398aa8cf891d6da85d730` |
| Prague | 22431084 | 21 | `0xef1ed97e3e0205c73f287f22c5900944da077daaadad17f57355fe7705cf3b05` |

Retrieved from Blockchair's decoded raw-block endpoint:

- https://api.blockchair.com/ethereum/raw/block/17034870
- https://api.blockchair.com/ethereum/raw/block/19426589
- https://api.blockchair.com/ethereum/raw/block/22431084

Independent explorer pages:

- https://etherscan.io/block/17034870
- https://etherscan.io/block/19426589
- https://etherscan.io/block/22431084

Reproduce any fixture offline, for example:

```sh
python3 script/encode_header.py test/fixtures/mainnet-prague.json
```

`cast keccak` of that hex output must equal the JSON `hash`. Each corresponding
Foundry test asserts that equality, the block number, and the published mixHash,
then uses `vm.roll` and `vm.setBlockhash` to draw an actual raffle with that header.

Field order is the execution header order: base 15 fields, base fee, withdrawals
root, blob gas used, excess blob gas, parent beacon block root, requests hash.
See [EIP-4399](https://eips.ethereum.org/EIPS/eip-4399),
[EIP-4895](https://eips.ethereum.org/EIPS/eip-4895),
[EIP-4844](https://eips.ethereum.org/EIPS/eip-4844),
[EIP-4788](https://eips.ethereum.org/EIPS/eip-4788), and
[EIP-7685](https://eips.ethereum.org/EIPS/eip-7685).


## Sepolia block 11921684

`sepolia-11921684.json` preserves the RPC header fields and published hash;
`SepoliaHeader.sol` embeds its full 23-field RLP so Foundry tests are offline.
Transaction bodies, withdrawals and uncles were omitted; these are RPC bodies,
not header fields. The `size` metadata is retained and ignored by the encoder.

- Number: `11921684` (`0xb5e914`), chain ID `11155111`.
- Published hash: `0x0beea75b48cae0d6c13bf5a289c3f64ea9e4473bfacd2f9709d5c0a827e73629`.
- prevRandao: `0xa85d0457a38eec5c572ee2db3f9802ca48d5c285d1860be36df2f4e4219c6c5d`.
- blockAccessListHash: `0xcd492c9aa474ff09c0758a0dd73c25506264d7ff66193b7d9478c079b0d8a033`.
- slotNumber: `0xad6069`.

Retrieved on 2026-10-18 using `eth_getBlockByNumber("0xb5e914", false)` from
[dRPC](https://sepolia.drpc.org). The same header fields and published hash were
independently returned by [PublicNode](https://ethereum-sepolia.publicnode.com),
[Tenderly](https://sepolia.gateway.tenderly.co), and
[thirdweb](https://sepolia.rpc.thirdweb.com). No provider credentials are needed
for the fixtures or their tests.

After the Prague fields, `blockAccessListHash` is a byte string at index 21 and
`slotNumber` is an RLP integer at index 22, in that order. Encoding this fixture
and computing Ethereum Keccak yields the published hash above. The former
encoder rejected these fields on this exact fixture; dropping them changes the
hash and cannot produce a valid draw header.

`test/test_encode_header.py` checks the encoder against all four published hashes,
confirms that its RLP matches the embedded Solidity fixtures, and rejects unknown
fields and missing intermediate fork fields. `test/BlockHeader.t.sol` verifies
the decoded number/prevRandao and the `draw` result for all four real headers.
