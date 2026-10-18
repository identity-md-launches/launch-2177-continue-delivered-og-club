# Additional contributor tests

These tests extend the delivered suite without changing application code,
configuration, deployment inputs, or dependencies. They run offline with the
existing Foundry and OpenZeppelin dependencies.

| File | Additional coverage |
| --- | --- |
| `FeeFlowInvariant.t.sol` | Four actors stake, partially/full unstake, spend points, propose four-leaf Merkle seasons, partially claim, cancel, release, and restake payouts. Separate campaigns use ordinary and 7.5% recipient-tax tokens, six token decimals, and a rate of `3e18 + 17`. |
| `RaffleSequenceInvariant.t.sol` | Four actors and up to four raffles with two pools each; capped/uncapped entry, cancellation, time/block advancement, commit, expired targets, valid/corrupted headers, permissionless claims, authorized redirection, and invalid/duplicate claims. |
| `RaffleAtomicity.t.sol` | Late failures after earlier wallet mints, a rejecting final recipient and its recovery, failed creation after an earlier pool was stored, cumulative prize-count overflow, independent claim bitmaps, and shuffled/fragmented multi-item claims with duplicate item IDs. |
| `TokenFailureAtomicity.t.sol` | A token that mutates balances then returns false; failure after the unstake fee has already transferred; packed stake overflow; dust exits; payout rollback after another allocation was paid; sender surcharges with multiple reservations; and no-return token payouts. |

The fee-flow campaigns use a closed token economy: each actor receives its
initial tokens once, and the vault receives only unstake fees. Ghost balances
track token transfers and burns, not contract-reported stakes. Points are checked
against the complete time integral of independently tracked balances, with one
final division, rather than reproducing the implementation's checkpoint and
remainder algorithm. Every season's reserve is independently summed from unpaid
allocations. Failed calls leave these models unchanged. At the end of each
sequence, every actor must still be able to withdraw its entire stake.

The raffle campaign records successful purchases and intended NFT recipients.
At drawing, it checks distinct tickets, ticket bounds, winner counts, and prize
multisets without implementing the Feistel algorithm again. It snapshots these
validated results and checks their stability after subsequent actions. Minted
supply and each wallet's receipts must equal consumed win bits. After every
random history, it completes all noncancelled raffles and claims all remaining
wins; total supply must equal the sum of their winner counts. Synthetic headers
are authenticated using `vm.setBlockhash`, with a consistent header per block
number. The existing real Sepolia fixture tests remain in the full suite.

Each new invariant campaign runs 128 sequences of depth 96 with unexpected
reverts treated as failures. Selectors target only the handlers. Known economic
transitions are seeded so the invariants never pass merely because no stake,
season, draw, or claim exists. Intentional invalid actions assert their exact
custom errors; a successful invalid action fails the test. The fragmented-claim
property runs 512 cases. Inputs are bounded without `vm.assume` or `vm.setEnv`.

Scope limits: these are finite fuzz campaigns, not a proof of statistical
uniformity, censorship resistance, or correctness of rebasing/dishonest tokens.
The fee-flow campaigns omit unsolicited staking donations, as the existing
donation regression covers their separation from stake accounting. They test
recipient taxes, not support for extra sender debits; the latter must revert.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4527dd7e19d2b4b8167581d582f24426775869593d2ed8fe03317cc41c942f06 forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```
