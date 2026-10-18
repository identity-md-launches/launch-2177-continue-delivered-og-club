# OG Club launch adaptation

This revision replaces the retired lootbox flow with staking-funded furniture
raffles and a farming fee vault. It preserves the existing furniture behavior
except the requested proposal lapse. No deployment or broadcast was performed.
The project's build configuration, dependencies, `lib/`, and protected paths were
not changed. All added code and fixtures are ordinary repository files.

The delivered tree passed **136 tests** locally before changes with the supplied
seed, rather than the 148 stated in the brief. The retired box tests are replaced
by tests of the new product; the retained furniture and header behavior remains
covered. The pinned factory and owner checks were read before implementation.

## Changes and reasons

| Files | Change and reason |
| --- | --- |
| `src/OGClubBox.sol` | Removed as explicitly requested. Its token-paid purchases, pause switch, mutable fee destination and box-opening/delivery logic are not carried into the replacement contracts. |
| `src/OGClubStaking.sol` | Added unlocked staking, deposits measured by actual receipt, a fixed rounded-up 100-bps unstake fee to an immutable vault, and exact time-weighted point accrual. Only designated spenders can consume points; ownership alone gives no point or stake adjustment power. Spender bootstrap/delay/expiry/revoke mirror furniture. Required by task 1. |
| `src/OGClubStaking.sol` | Account balance/time/fraction share one slot; point balance uses a second. Retained fractional numerators prevent checkpoint-frequency loss, even across exits. Token decimals are cached on first use (0–18) so constructors never call dependencies. Checked uint128 stakes, uint48 timestamps and uint96 rate bounds make the arithmetic/storage packing explicit; Math.mulDiv handles wide products. Token calls use SafeERC20 and a shared reentrancy guard, and withdrawals reject excessive sender debits. |
| `src/OGClubRaffle.sol` | Added immutable raffle windows, notice, bounded multi-item pools, per-pool wallet caps and point-only entry. One packed slot stores each contiguous entry range. Commit/draw are permissionless, authenticate the full header and target number, preserve prevRandao, and permit retargeting only at target + 257 or later. Required by task 2. |
| `src/libraries/Permutation.sol` | Added an internal eight-round Keccak Feistel permutation with cycle walking. Ticket and expanded-prize permutations use independent, raffle/pool/chain-specific keys. This gives exactly min(prizes, tickets) unique winning tickets and random unawarded prize positions without entrant-sized state or draw loops. Maximum domain size is 2**48 - 1. |
| `src/OGClubRaffle.sol` | Claims authenticate a supplied entry, mark a win bitmap, and batch adjacent wins for one wallet through furniture.mintBatch. Anyone can deliver to the recorded wallet; only that wallet can redirect through claimTo. Callback/mint failures roll back without changing the result; claims may be retried indefinitely. No scan of entrants or tickets is needed to claim. |
| `src/OGClubFarmVault.sol` | Added immediate reservations capped at half the unreserved balance, three-day opening delay, seven-day proposal interval, cancellation before opening, double-hashed OpenZeppelin Merkle proofs, one claim per account/season, and release after a 90-day claim window. Only claims transfer tokens. All reservation mutations share the claim reentrancy guard; see the reproduced callback case below. Required by task 3. |
| `src/OGClubFurniture.sol` | Activation and cancellation treat proposals as absent after maturity + 7 days. The final second remains valid, re-proposing resets the delay, and revocation clears stale proposals. Changed the bootstrap comment from box to raffle. All other ownership, minting, supply, transfers, metadata and royalty behavior is preserved. Required by task 4 and audit a03021d58124. |
| `src/libraries/BlockHeader.sol`, `src/mocks/MockOG.sol` | Preserved without source changes. BlockHeader already accepts and validates arbitrary trailing RLP fields. MockOG remains intentionally unrestricted and testnet-only, as requested. |
| `script/encode_header.py` | Appended blockAccessListHash then integer slotNumber after requestsHash. Added an explicit non-header RPC metadata allowlist; any other unknown field, including null, is refused. Gap detection remains. Required by task 4 and audit 7b80583eb997. |
| `test/fixtures/sepolia-11921684.json`, `test/fixtures/SepoliaHeader.sol`, `test/fixtures/SOURCES.md` | Added the real 23-field Sepolia header and published hash, with provenance independently checked against four RPC providers. Retained the three original mainnet fixtures; updated their test description from box opening to raffle draw. No test needs a live network. |
| `script/Deploy.s.sol` | Deploys furniture, vault, staking and raffle with static constructor arguments and explicit ownership. A separate Sepolia/local helper adds MockOG. Mainnet uses an existing token, Safe owner and RAFFLE_NOTICE=604800. The chosen default accrual is the named 1e18 constant. No signer/key is read by this work and no deployment was invoked. |
| `launch.json` | Replaced OGClubBox with the vault, staking and raffle, referencing only earlier deployments. Sepolia uses MockOG, the explicit $owner throughout, accrual 1e18 and notice zero. The explicit task requests this update and takes precedence over the quoted background deferring the manifest. Notes identify the two necessary first owner grants; there is no unsupported initializer or predicted-address bootstrap. |
| `README.md` | Replaced the obsolete box guide with constructor/setup instructions, staking arithmetic and bounds, raffle/claim APIs, Merkle allocation format, exact time boundaries, mainnet inputs, role powers, randomness/retarget bias, token assumptions and reproducible EIP-8037 gas projections. |
| `ADAPTATION.md` | Replaced historical box adaptation notes with this revision's changes, reproductions, decisions and validation. |

The selected rate of one point per token-day is a deployment default, not a
fixed raffle price; owners choose pool ticket prices when announcing raffles.
The 90-day vault period is measured **from claims opening**, with claims ending
at `opensAt + 90 days`. Timestamps, caps and proposals use the exact inclusive
or exclusive boundaries documented in the README. ERC-20 taxes deducted from a
transfer reduce recipients' net receipts; sender-extra-debit and rebasing tokens
are unsupported. Donations to staking do not become stake or points.

## Tests changed or added

- Preserved `test/OGClubFurniture.t.sol` and `test/FurnitureInvariant.t.sol`.
  Added standalone `test/RoleLifecycle.t.sol` for minter and spender bootstrap,
  maturity, final activation second, expiry, cancellation, re-proposal,
  revocation and ownership handover. The provided lapse proof also passes in
  disposable scratch; permanent regression coverage does not depend on it.
- Replaced `test/Deployment.t.sol` with five-application ownership/dependency,
  absent-dependency constructor, runtime size/forbidden-opcode, parameter bound,
  mock policy and owner-grant checks. `test/test_launch.py` additionally verifies
  the actual manifest's order, argument values/types and nonpayable constructors
  against compiler ABIs.
- Updated `test/BlockHeader.t.sol` to draw raffles using all four real headers,
  while preserving canonical-RLP, field-boundary and malformed-input tests.
  Added `test/test_encode_header.py` for real-fixture Keccak, embedded RLP,
  appended-field order, unknown fields and gaps.
- Added `test/OGClubStaking.t.sol` for exact accrual, fractional checkpoints,
  fees including tiny amounts, live balance changes, decimal normalization,
  extreme packed arithmetic bounds, transfer-tax/false/no-return tokens,
  callbacks, authorization and donation isolation.
- Added `test/OGClubRaffle.t.sol` for notices, windows, caps, pool/line maxima,
  huge ticket domains, header authentication/expiry, exact winner counts,
  complete multi-item supply, randomized unawarded items, duplicate bitmap
  claims, wrong entries, arbitrary claim callers, redirection, mixed wallets,
  revoked minter recovery, rejected receivers and reentrancy.
- Added `test/Permutation.t.sol`: fuzzed small-domain bijections and distinct,
  in-range outputs in large domains, plus invalid arguments.
- Added `test/OGClubFarmVault.t.sol` for delay/cap/interval/cancel boundaries,
  sorted proofs and double hashing, wrong account/amount/season, dishonest-root
  budget limits, transfer failure atomicity, claim expiry/release and callbacks.
- Added `test/StakingInvariant.t.sol` with independent integrated-balance ghosts:
  token custody equals total stakes, and earned points minus authorized spending
  equals on-chain points. Runs with both ordinary and 2%-tax tokens. Added
  `test/VaultInvariant.t.sol` for all live reservations, claim-only outflows,
  funding conservation and balance >= reserved across propose/claim/cancel/release.
- Added `test/Gas.t.sol`: isolated-call gas and state-diff slot counts for first
  stake, unstake, entry, draw, and one/ten claims. The README's EIP-8037 figures
  explicitly project storage repricing, rather than claiming Cancun implements it.
- Added shared `test/helpers/RaffleTestBase.sol` and `test/helpers/TokenMocks.sol`.
  Preserved the independent RLP encoder `test/helpers/HeaderBuilder.sol`.
- Retired box-only suites: `BoxInvariant`, `Delivery`, `DeliveryEdges`,
  `EdgeCases`, `FixedOdds`, `MinterLifecycleInvariant` (the old box-integrated
  version), `MultiActorInvariant`, `OpenGas`, `Opening`, `OwnerTrustBoundaries`,
  `Payments`, `Rolls`, `SeasonNotice`, `SeasonNoticeInvariant`, and `Seasons`;
  also retired `helpers/BoxTestBase.sol` and the box-specific
  `helpers/Adversaries.sol`. Their removed behavior belongs to the retired box.

## Imported audit reproduction

All five reported observations reproduced; none was dismissed as unreproduced.

| Audit ID | Evidence and resolution |
| --- | --- |
| `a03021d5812410a25cf5ef465709dc7c7c28b03f94a7e1fabd9e03db4435e885` | Copied the pinned proof into scratch and ran it before changes: `test_ProposalLapsesSevenDaysAfterMaturity` failed with **lapsed proposal was still activatable**. The final-window proof passed. Both pass after the fix, and permanent lifecycle tests cover expiry at +1 second and the inclusive final second. |
| `12fead547779e198a8c19f555313861d437474eb407f82a9e909f0a10aa9a267` | Original source exposes setPaused and setVault; the baseline payment/season and multi-actor suites exercise those owner controls, including a changed vault payment destination. Removed the box as requested. Replacement tests verify no pause/vault-setter/owner-withdraw selectors, an immutable staking vault and unchanged started raffle terms. |
| `7b80583eb99736786814ef984407c95ec641f493cfcd148eefeba7528191b02b` | Ran the original encoder on the retrieved Sepolia 11921684 fixture: it exited 1 with **unsupported newer header fields: update the encoder**. The revised 23-field encoding hashes to `0x0beea75b48cae0d6c13bf5a289c3f64ea9e4473bfacd2f9709d5c0a827e73629`, and the same bytes pass a raffle draw. Unknown fields are still rejected. |
| `91c8e4a7d05ac88b35d0d2ef30965180a57af699bb10b78ceceb9bb24b8daa56` | The original manifest contained MockOG/furniture/box only. The constructor-only factory format has no role-grant calls. Updated it for the five requested contracts; README/notes require the owner to make the raffle the first minter and first spender. The deployment test verifies roles start unset and those owner calls grant them immediately. No initialization workaround was added. |
| `a76ca69162192477ef2a7ec9c1c2a1ed4bc074d0f59b8eb546a2f11b4e2aa857` | The original mock and baseline test allow any caller to mint beyond initial supply; the replacement deployment test preserves this demonstration. Retained MockOG exactly as requested for Sepolia. Mainnet guidance uses the existing OG token and excludes MockOG. Testnet points and odds have no scarcity guarantee. |

An additional cross-function reentrancy case was reproduced during local review:
a token callback reaching a contract owner could propose a new season while a
claim's transfer was in flight, computing the 50% cap before the payout's token
debit. `test_OwnerCallbackCannotReserveAgainstAnInFlightPayout` fails when only
claim is guarded and passes when all reservation mutations share the guard.
The delivered vault includes that guard. This prevents reservation decisions
based on transient, pre-debit balances.

## Validation

- `forge build` and `forge build --sizes` pass with the unchanged project configuration.
- **104 permanent Foundry tests pass**, with zero failures or skips; the full
  local run also passes the two disposable audit-proof tests (106 total).
  `forge test` uses the requested seed
  `0x4527dd7e19d2b4b8167581d582f24426775869593d2ed8fe03317cc41c942f06`.
- `forge fmt --check` and `git diff --check` pass.
- Six offline Python encoder/manifest checks pass using the standard library
  and the existing Foundry binaries.
- Runtime bytes: MockOG **1,851**, furniture **9,044**, vault **4,199**, staking
  **6,329**, raffle **9,854**; all are below 24,576, and local deployment tests
  scan every runtime for the forbidden opcodes while skipping PUSH payloads.
- The pinned protected harness needs verifier-provided factory/deployment inputs;
  it was read, not invoked with fabricated inputs. Local constructor tests cover
  its relevant ownership, absent-dependency, runtime and opcode properties.
- No Slither, Mythril, chain deployment, broadcast or external-chain transaction
  simulation was performed. RPC use was read-only retrieval of the header fixture.
