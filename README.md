# OG Club staking, furniture and raffles

OG Club awards ERC-1155 furniture through raffles paid with nontransferable points
accrued by staking OG. There are no lootboxes or token-paid furniture purchases.
This Foundry project uses the existing Solidity 0.8.26/Cancun configuration and
vendored OpenZeppelin 5.0.2 / forge-std 1.9.7 dependencies ([VENDOR.md](VENDOR.md)).
Builds and tests require no RPC, secrets, FFI, or downloaded dependencies.

## Contracts and configuration

All constructors are nonpayable, use explicit owners, and make no dependency
calls. They can run on an empty chain through the launch factory. Contracts are
immutable implementations, without proxies, upgrades, pauses or owner sweeps.
Ownership uses OpenZeppelin's two-step transfer. Libraries are internal/inlined.

| Contract | Constructor arguments, in order |
| --- | --- |
| `MockOG` | initial recipient (Sepolia/local only) |
| `OGClubFurniture` | owner, initial royalty receiver |
| `OGClubFarmVault` | token, owner |
| `OGClubStaking` | token, immutable vault, owner, pointsPerTokenDay |
| `OGClubRaffle` | staking, furniture, owner, immutable raffleNotice |

The supplied `launch.json` is for **Sepolia, chain ID 11155111**, and deploys these
five contracts in that order. `$owner` is the launch's configured owner; contract
references resolve to the preceding deployments. MockOG deliberately has
unrestricted minting, so anyone can acquire arbitrary stake and raffle points on
this test network. Its initial trillion-token supply is not a cap. Do not reuse
this manifest for mainnet.

The selected testnet accrual rate is **1e18 point units per whole token per day**
(one point); `Deploy.DEFAULT_POINTS_PER_TOKEN_DAY` names this default. Ticket
prices are owner-announced point amounts in each pool, not an ERC-20 payment.
Other fixed limits are three blocks for `TARGET_DELAY`, 32 pools and 128 total
prize lines per raffle, and 30 days for the maximum raffle notice.

## Owner setup and mainnet handoff

The factory performs constructor deployments only. **It cannot grant the two
raffle roles.** After deployment, the configured owner must execute these calls,
using the confirmed deployed raffle address, before creating the first raffle:

1. `furniture.grantMinter(raffle)` as the furniture's **first successful grant**.
2. `staking.grantSpender(raffle)` as staking's **first successful grant**.
3. Verify `minters(raffle)` and `spenders(raffle)` are true, set the furniture
   base URI, then create the announced raffles.

The first grant in each contract is immediate and permanently spends that
contract's bootstrap. Granting another address first makes the raffle wait. All
later grants, including re-grants of revoked roles, are seven-day proposals.
Anyone can activate in `[activatesAt, activatesAt + 7 days]`, inclusive. At the
next second the proposal is absent for activation/cancellation; its raw mapping
value may remain until a new proposal or revocation. Re-proposing restarts the
full delay. Cancel only removes a live proposal; revoke immediately clears both
permission and any proposal. Neither supply nor ownership handover resets this.

For a separate **mainnet** launch:

- Use the **existing OG token**, never deploy MockOG. The actual token address
  is an operator input, not a guessed address in this repository.
- Use a **fresh deployer** and set **OWNER to a Safe**. The deployer/factory gains
  no ownership and cannot perform the Safe's role grants.
- Set **RAFFLE_NOTICE=604800** (seven days). Sepolia uses zero.
- `script/Deploy.s.sol` takes `TOKEN`, `OWNER`, `RAFFLE_NOTICE`, and optionally
  `POINTS_PER_TOKEN_DAY` (default 1e18). Its `deploy` helper builds the four
  production applications; `deploySepolia` additionally creates MockOG and is
  restricted to Sepolia/local chain IDs. Both leave role grants to the owner.

No contract has been deployed or broadcast as part of this work.

## Staking and points

Approve the staking contract, then call `stake(amount)`. The stake credited is
its actual token balance increase, so a fee deducted from a deposit cannot mint
extra stake or points. `unstake(amount)` is available immediately, including in
the same block as a stake. The immutable vault receives
`ceil(amount * 100 / 10000)` token units and the remaining units go to the staker.
A one-unit withdrawal pays one unit in fees; splitting withdrawals cannot avoid
fees. No points are awarded on unstaked balances.

For a balance held over `seconds`, accrual in point-wei is:

```text
balanceInTokenUnits * pointsPerTokenDay * seconds / (10**tokenDecimals * 86400)
```

`pointsOf(account)` includes pending accrual. Balances are checkpointed before
stake changes and point spending. Division remainders persist, including through
a full exit, so many small checkpoints have exactly the same result as one large
checkpoint. `spendPoints(account, amount)` is available only to authorized
spenders, and never makes an external token transfer. Points have no transfer,
approval, mint, or admin-adjustment function. Zero-point spends are harmless
checkpoints that retain fractions.

Each account occupies **two slots**: `uint128 balance`, `uint48 updatedAt` and
`uint80 remainder` packed together, plus `uint256 points`. The per-account stake
limit is `2**128 - 1` token units; the maximum rate is `2**96 - 1` point units per
token-day. Checked casts and full-precision multiplication prevent truncation and
intermediate overflow. The timestamp range extends to `2**48 - 1` seconds.

Token decimals (0–18, including OG/MockOG's 18) are read and fixed on the first
stake, not in the constructor. This supports ordinary fixed-balance ERC-20s with
stable metadata, including tokens returning no transfer boolean and fees deducted
from the transferred amount. Outbound transfers must debit exactly the requested
amount; extra sender-side fees revert atomically. Recipients of a taxed token
receive less after that token's own fee. Rebasing/reflection tokens and dishonest
balance reporting are unsupported. Unsolicited transfers to staking are surplus,
not stake or points, and cannot be swept. The balance-equals-total-staked invariant
applies to stake/unstake flows without unsolicited donations or rebases.

## Raffles, winning tickets and claims

The owner calls `createRaffle(opensAt, closesAt, pools)` with a nonempty pool list.
Opening must be at least `now + raffleNotice`; closing must be later. Each pool
has a display-only `uint8 tier`, positive point ticket price, a per-wallet ticket
cap (zero means unlimited), and one or more `{itemId, quantity}` prizes with
positive quantities. Item ID zero and repeated item IDs are supported. Caps are
per wallet **per pool per raffle**, not identity-based or Sybil resistant.
Quantities and total sold tickets per pool are at most `2**48 - 1`.

The terms and prize list cannot be edited. The owner can cancel only **before**
opening, when entry has not yet been possible. `enter(raffleId, poolId, tickets)`
works during `[opensAt, closesAt)`, spends `tickets * ticketPrice`, and appends an
entry for the sender. It records the contiguous half-open range `[first, end)` in
one storage slot, regardless of the ticket count. Ticket indices, pool indices,
entry indices and win indices start at zero; raffle IDs start at one. Tickets
cannot be transferred. Failed spending rolls back the range and cap update.

At or after closing, anyone calls `commitDraw(raffleId)` to target the block
**three blocks ahead**. Anyone may then call `draw(raffleId, header)` when
`target < block.number <= target + 256`. The entire canonical RLP header must
hash to `blockhash(target)`, and its decoded block number must equal the target.
Its `prevRandao` is stored as the seed, even when zero. Drawing never mints or
iterates over pools, tickets or entrants. After drawing the seed cannot change.

Let `W = min(prizes, ticketsSold)` for a pool. The valid wins are exactly
`k = 0 ... W-1`. `winningTicket(raffleId, pool, k)` evaluates an eight-round
Keccak Feistel permutation with cycle walking over ticket indices. `prizeOf`
evaluates a **separate, domain-separated permutation** over the expanded prize
positions and locates its item by binary search of cumulative quantities.
Thus each ticket wins at most once, wallets may win multiple times, and a pool
with enough tickets awards every listed quantity exactly. With fewer tickets,
the unused prize positions are random too; they are never minted.

Both permutations also bind the seed to the chain, raffle contract, raffle ID
and pool. Cycle walking uses the next power-of-four domain (less than four times
the requested size). It is an invertible pseudorandom selection without modulo
bias or a table of entrants. Walk length depends on the seed; it has a short
expected cost, not a fixed worst-case gas bound.

Anyone calls `claim(raffleId, pool, wins)`, where each win is `{k, entry}` and the
supplied entry must contain `winningTicket(k)`. It pays the entry wallet, never
the caller. Claimed win indices are recorded in a bitmap. Adjacent claims for
the same wallet share one `furniture.mintBatch`; grouping by wallet saves gas.
The on-chain work grows with the **wins submitted**, independently of entrant
and ticket counts (prize lookup is bounded by 128 lines). Read `Entered` events
or `getEntry` to locate ticket ranges off chain.

`claimTo(raffleId, pool, wins, to)` requires the caller to be the wallet of **every**
supplied entry and a nonzero recipient. It lets contract wallets redirect prizes.
Receiver or mint-permission failures roll back that transaction's claims and
mints; they remain retryable with the same results indefinitely. Submit subsets
to isolate a rejecting recipient. Claims are guarded against receiver reentrancy.

### Randomness and owner trust

This is the requested on-chain future-block randomness, not an external VRF.
Validators can influence/censor the target block and its prevRandao, and callers
can choose when to commit after closing. If **nobody draws** by target + 256,
anyone can re-commit beginning at target + 257, choosing a new future target.
An operator who withholds unfavorable draws, especially with censorship or no
independent keeper, can obtain another seed and bias results. Permissionless
drawing lets an independent party preserve an available outcome; it does not
eliminate these biases. Operators must monitor closed raffles and retrieve
headers inside the blockhash window. A finalized draw cannot be retargeted.

Owners cannot directly change stakes, point balances or drawn outcomes. They do
control spender authorization; an authorized spender can consume any account's
points, so later grants need scrutiny during their notice window. Furniture
minters can mint arbitrary IDs/quantities outside raffles. Revoking the raffle's
roles stops new point spending or prize delivery until reinstated, although
staking exits remain available and drawn claims retain their results. Prize
quantities are per pool, not global collection scarcity limits.

Furniture retains its original supply tracking, ERC-1155 transfers, metadata URI
format, permanent metadata freeze, and ERC-2981 royalties: initially 5%, owner
adjustable up to 10%. Its owner has no confiscation, privileged transfer or burn
right. Royalties are informational; marketplace enforcement is external.

## Farming vault

Unstake fees accumulate in `OGClubFarmVault`. The owner publishes a farming
allocation with `proposeSeason(root, total)`. Total must be positive and at most
`floor((tokenBalance - reserved) / 2)`. It is reserved immediately, claims open
three days later, and the next proposal must wait at least seven days after the
previous proposal even if that proposal was canceled.

Use sorted-pair OpenZeppelin Merkle trees (compatible with StandardMerkleTree)
and exactly this double-hashed leaf, with the types shown:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(
    uint256(seasonId), address(account), uint256(amount)
))))
```

Season IDs begin at one; generate allocations for the correct ID. Include each
account once per season, since the contract pays only one allocation per account.
Keep the sum of allocations equal to `total`; a root alone cannot prove that sum,
and the contract refuses claims above the remaining season budget. Anyone may
submit `claim(seasonId, account, amount, proof)`, which pays only that account.
There is no relayer redirect. Zero allocations are valid but unnecessary.

`cancelSeason` is owner-only and works strictly before claims open. Claims are
valid during `[opensAt, opensAt + 90 days)`. At exactly `opensAt + 90 days`, claims
stop and the owner may call `releaseSeason` to unreserve the unpaid balance.
Cancellation and release **never transfer tokens**; the released funds become
eligible for later seasons. The owner has no other token-moving function.
The owner chooses recipients/root/total and could include itself in a valid
season: this remains a trust assumption subject to the budget and time limits.

## Header encoder and offline fixtures

`script/encode_header.py` takes an `eth_getBlockByNumber` JSON object or response
wrapper from a file or stdin. It encodes fields after `requestsHash` in the order
**blockAccessListHash, slotNumber** (slotNumber is an integer). It refuses gaps
and all unknown keys except explicitly allowlisted non-header RPC metadata.

```sh
python3 script/encode_header.py test/fixtures/sepolia-11921684.json
```

Sepolia block **11921684** has published hash
`0x0beea75b48cae0d6c13bf5a289c3f64ea9e4473bfacd2f9709d5c0a827e73629`.
The JSON and embedded RLP are checked both against that hash and through raffle
`draw`. Existing real Shanghai, Cancun and Prague fixtures remain tested. See
[test/fixtures/SOURCES.md](test/fixtures/SOURCES.md) for provenance. Always compare
`cast keccak` of the encoded header with the published hash before submitting it.

## Gas and EIP-8037

The project still targets Cancun. These are isolated-call measurements, followed
by a **storage-cost projection**, not a claim to execute the future fork.
[EIP-8037](https://eips.ethereum.org/EIPS/eip-8037) specifies 64 state bytes per
new storage slot and CPSB 1530: **97,920 state gas per fresh slot**, replacing
20,000 Cancun gas. The projected total adds **77,920 per durable fresh slot**
across all callees. Companion EIPs, transaction intrinsic/calldata gas and
refunds are not modeled; these are gross call costs, not receipt or gas-limit
estimates. ERC-20 transfers and ERC-1155 receiver behavior can change costs.

| Operation | Measured Cancun call gas | Fresh slots | EIP-8037 state gas | Storage-repriced call gas |
| --- | ---: | ---: | ---: | ---: |
| First-ever stake, fresh staker | 120,547 | 3 | 293,760 | 354,307 |
| Partial unstake, first checkpoint and first vault fee | 110,662 | 2 | 195,840 | 266,502 |
| First entry, 10 tickets, first point checkpoint | 155,364 | 4 | 391,680 | 467,044 |
| Draw, 23-field header | 74,312 | 1 | 97,920 | 152,232 |
| Claim 1 win to a fresh furniture wallet | 160,885 | 4 | 391,680 | 472,565 |
| Claim 10 distinct items to a fresh furniture wallet | 816,170 | 22 | 2,154,240 | 2,530,410 |

Measured with MockOG, 1e18 accrual, preapproved spending, and freshly granted
roles. Claim rows start with zero collection supply, mint to one EOA, and set the
first claim bitmap word. The ten-win pool has ten different IDs, so it creates
ten recipient balances and ten per-ID supply slots; repeated IDs cost less.
Draw uses the deterministic synthetic header in the gas test; real header sizes
change decoding costs. Permutation costs vary with the seed and domain sizes.
The two-slot staking account, one-slot entry and claim bitmap limit new state.
Reproduce both measurements and the asserted new-slot counts:

```sh
forge test --match-contract GasTest --isolate -vv
```

## Local checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4527dd7e19d2b4b8167581d582f24426775869593d2ed8fe03317cc41c942f06 forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

Tests cover accrual fractions and packed bounds, taxed/nonstandard tokens,
reentrancy, spender/minter lapse, raffle time/cap/header boundaries, retargeting,
permutation bijections, exact prize quantities, wrong entries and duplicate
claims, contract-wallet redirection, vault proofs and reserve deadlines. Stateful
invariants check stakes against token custody, independently integrated accrual
minus spending, and vault balances against all remaining reservations. The
retained furniture suite checks supply, transfer authorization, royalties and
frozen metadata. [ADAPTATION.md](ADAPTATION.md) records the changes and audit
reproductions.
