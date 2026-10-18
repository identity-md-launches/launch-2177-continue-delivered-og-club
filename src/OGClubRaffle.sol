// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OGClubStaking} from "./OGClubStaking.sol";
import {OGClubFurniture} from "./OGClubFurniture.sol";
import {BlockHeader} from "./libraries/BlockHeader.sol";
import {Permutation} from "./libraries/Permutation.sol";

/// @notice Immutable raffle pools paid exclusively with staking points, with permissionless drawing and claims.
contract OGClubRaffle is Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;

    uint256 public constant TARGET_DELAY = 3;
    uint256 public constant MAX_RAFFLE_NOTICE = 30 days;
    uint256 public constant MAX_POOLS = 32;
    uint256 public constant MAX_PRIZE_LINES = 128;
    uint256 public constant MAX_TICKETS = type(uint48).max;

    OGClubStaking public immutable staking;
    OGClubFurniture public immutable furniture;
    uint256 public immutable raffleNotice;
    uint256 public raffleCount;

    struct Prize {
        uint256 itemId;
        uint256 quantity;
    }

    struct PoolInput {
        uint8 tier;
        uint256 ticketPrice;
        uint256 maxTicketsPerWallet;
        Prize[] prizes;
    }

    struct Raffle {
        uint64 opensAt;
        uint64 closesAt;
        uint64 targetBlock;
        uint8 poolCount;
        bool cancelled;
        bool drawn;
        bytes32 seed;
    }

    /// @dev Prize positions [previous end, end) all contain itemId; binary search costs at most 8 comparisons.
    struct PrizeLine {
        uint256 itemId;
        uint48 end;
    }

    /// @dev One storage slot per entry, regardless of its ticket count. Range is [first, end).
    struct Entry {
        address wallet;
        uint48 first;
        uint48 end;
    }

    struct Pool {
        uint8 tier;
        uint48 maxTicketsPerWallet;
        uint48 ticketsSold;
        uint48 prizeCount;
        uint256 ticketPrice;
        PrizeLine[] prizes;
        Entry[] entries;
    }

    struct Win {
        uint256 k;
        uint256 entry;
    }

    mapping(uint256 => Raffle) public raffles;
    mapping(uint256 => mapping(uint256 => Pool)) private _pools;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public ticketsOf;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) private _claimed;

    error InvalidAddress();
    error InvalidNotice();
    error InvalidWindow();
    error InsufficientNotice();
    error InvalidPools();
    error InvalidPrize();
    error InvalidRaffle();
    error InvalidPool();
    error RaffleCancelled();
    error AlreadyStarted();
    error EntryClosed();
    error InvalidTickets();
    error WalletCapExceeded();
    error RaffleStillOpen();
    error AlreadyDrawn();
    error TargetStillLive();
    error TargetUnavailable();
    error InvalidHeader();
    error NotDrawn();
    error InvalidWin();
    error InvalidEntry();
    error AlreadyClaimed();
    error NotEntryWallet();
    error EmptyClaim();

    event RaffleCreated(uint256 indexed raffleId, uint256 opensAt, uint256 closesAt, uint256 pools);
    event PoolCreated(
        uint256 indexed raffleId, uint256 indexed pool, uint8 tier, uint256 ticketPrice, uint256 walletCap
    );
    event PrizeAdded(uint256 indexed raffleId, uint256 indexed pool, uint256 itemId, uint256 quantity);
    event RaffleCancelledEvent(uint256 indexed raffleId);
    event Entered(
        uint256 indexed raffleId,
        uint256 indexed pool,
        address indexed wallet,
        uint256 entry,
        uint256 first,
        uint256 end
    );
    event DrawCommitted(uint256 indexed raffleId, uint256 targetBlock);
    event Drawn(uint256 indexed raffleId, bytes32 seed);
    event PrizeClaimed(
        uint256 indexed raffleId, uint256 indexed pool, uint256 indexed k, address wallet, address to, uint256 itemId
    );

    constructor(OGClubStaking staking_, OGClubFurniture furniture_, address initialOwner, uint256 raffleNotice_)
        Ownable(initialOwner)
    {
        if (address(staking_) == address(0) || address(furniture_) == address(0)) revert InvalidAddress();
        if (raffleNotice_ > MAX_RAFFLE_NOTICE) revert InvalidNotice();
        staking = staking_;
        furniture = furniture_;
        raffleNotice = raffleNotice_;
    }

    function createRaffle(uint256 opensAt, uint256 closesAt, PoolInput[] calldata pools)
        external
        onlyOwner
        returns (uint256 raffleId)
    {
        if (closesAt <= opensAt || closesAt > type(uint64).max) revert InvalidWindow();
        if (opensAt < block.timestamp + raffleNotice) revert InsufficientNotice();
        if (pools.length == 0 || pools.length > MAX_POOLS) revert InvalidPools();
        raffleId = ++raffleCount;
        raffles[raffleId] = Raffle(uint64(opensAt), uint64(closesAt), 0, uint8(pools.length), false, false, bytes32(0));
        uint256 lines;
        for (uint256 i; i < pools.length; ++i) {
            PoolInput calldata input = pools[i];
            lines += input.prizes.length;
            if (
                input.ticketPrice == 0 || input.maxTicketsPerWallet > MAX_TICKETS || input.prizes.length == 0
                    || lines > MAX_PRIZE_LINES
            ) {
                revert InvalidPools();
            }
            Pool storage pool = _pools[raffleId][i];
            pool.tier = input.tier;
            pool.ticketPrice = input.ticketPrice;
            pool.maxTicketsPerWallet = uint48(input.maxTicketsPerWallet);
            emit PoolCreated(raffleId, i, input.tier, input.ticketPrice, input.maxTicketsPerWallet);
            uint256 prizeCount;
            for (uint256 j; j < input.prizes.length; ++j) {
                Prize calldata prize = input.prizes[j];
                if (prize.quantity == 0 || prize.quantity > MAX_TICKETS - prizeCount) revert InvalidPrize();
                prizeCount += prize.quantity;
                pool.prizes.push(PrizeLine(prize.itemId, uint48(prizeCount)));
                emit PrizeAdded(raffleId, i, prize.itemId, prize.quantity);
            }
            pool.prizeCount = uint48(prizeCount);
        }
        emit RaffleCreated(raffleId, opensAt, closesAt, pools.length);
    }

    function cancelRaffle(uint256 raffleId) external onlyOwner {
        Raffle storage raffle = _raffle(raffleId);
        if (block.timestamp >= raffle.opensAt) revert AlreadyStarted();
        raffle.cancelled = true;
        emit RaffleCancelledEvent(raffleId);
    }

    function enter(uint256 raffleId, uint256 poolId, uint256 tickets) external nonReentrant returns (uint256 entryId) {
        Raffle storage raffle = _raffle(raffleId);
        if (block.timestamp < raffle.opensAt || block.timestamp >= raffle.closesAt) revert EntryClosed();
        Pool storage pool = _pool(raffleId, poolId);
        if (tickets == 0 || tickets > MAX_TICKETS - pool.ticketsSold) revert InvalidTickets();
        uint256 walletTickets = ticketsOf[raffleId][poolId][msg.sender] + tickets;
        if (pool.maxTicketsPerWallet != 0 && walletTickets > pool.maxTicketsPerWallet) revert WalletCapExceeded();
        uint256 first = pool.ticketsSold;
        uint256 end = first + tickets;
        entryId = pool.entries.length;
        pool.entries.push(Entry(msg.sender, uint48(first), uint48(end)));
        pool.ticketsSold = uint48(end);
        ticketsOf[raffleId][poolId][msg.sender] = walletTickets;
        // A failed spend (including a revoked spender) rolls back the range and cap accounting.
        staking.spendPoints(msg.sender, tickets * pool.ticketPrice);
        emit Entered(raffleId, poolId, msg.sender, entryId, first, end);
    }

    /// @notice Anyone commits after closing. An expired, undrawn target can be replaced after target + 256.
    /// @dev Withholding all draws until expiry permits a new seed and selection bias; see README.
    function commitDraw(uint256 raffleId) external {
        Raffle storage raffle = _raffle(raffleId);
        if (block.timestamp < raffle.closesAt) revert RaffleStillOpen();
        if (raffle.drawn) revert AlreadyDrawn();
        uint256 target = raffle.targetBlock;
        if (target != 0 && block.number <= target + 256) revert TargetStillLive();
        raffle.targetBlock = (block.number + TARGET_DELAY).toUint64();
        emit DrawCommitted(raffleId, raffle.targetBlock);
    }

    function draw(uint256 raffleId, bytes calldata header) external {
        Raffle storage raffle = _raffle(raffleId);
        if (raffle.drawn) revert AlreadyDrawn();
        uint256 target = raffle.targetBlock;
        if (target == 0 || block.number <= target || block.number > target + 256) revert TargetUnavailable();
        bytes32 hash = blockhash(target);
        if (hash == bytes32(0) || keccak256(header) != hash) revert InvalidHeader();
        (uint256 number, bytes32 randao) = BlockHeader.decode(header);
        if (number != target) revert InvalidHeader();
        raffle.seed = randao;
        raffle.drawn = true;
        emit Drawn(raffleId, randao);
    }

    function winnerCount(uint256 raffleId, uint256 poolId) public view returns (uint256) {
        Pool storage pool = _pool(raffleId, poolId);
        return pool.prizeCount < pool.ticketsSold ? pool.prizeCount : pool.ticketsSold;
    }

    function winningTicket(uint256 raffleId, uint256 poolId, uint256 k) public view returns (uint256) {
        _checkWin(raffleId, poolId, k);
        return Permutation.permute(k, _pools[raffleId][poolId].ticketsSold, _key(raffleId, poolId, 0));
    }

    function prizeOf(uint256 raffleId, uint256 poolId, uint256 k) public view returns (uint256 itemId) {
        _checkWin(raffleId, poolId, k);
        Pool storage pool = _pools[raffleId][poolId];
        uint256 position = Permutation.permute(k, pool.prizeCount, _key(raffleId, poolId, 1));
        uint256 low;
        uint256 high = pool.prizes.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (position < pool.prizes[mid].end) high = mid;
            else low = mid + 1;
        }
        return pool.prizes[low].itemId;
    }

    /// @notice Anyone delivers wins to the corresponding entry wallets. Submit subsets to isolate rejecting receivers.
    function claim(uint256 raffleId, uint256 poolId, Win[] calldata wins) external nonReentrant {
        _claim(raffleId, poolId, wins, address(0));
    }

    /// @notice Only the wallet of every supplied entry may redirect its own prizes.
    function claimTo(uint256 raffleId, uint256 poolId, Win[] calldata wins, address to) external nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        _claim(raffleId, poolId, wins, to);
    }

    function isClaimed(uint256 raffleId, uint256 poolId, uint256 k) public view returns (bool) {
        return _claimed[raffleId][poolId][k >> 8] & (uint256(1) << (k & 255)) != 0;
    }

    function getPool(uint256 raffleId, uint256 poolId)
        external
        view
        returns (
            uint8 tier,
            uint256 ticketPrice,
            uint256 maxTicketsPerWallet,
            uint256 ticketsSold,
            uint256 prizeCount,
            uint256 entries
        )
    {
        Pool storage pool = _pool(raffleId, poolId);
        return
            (
                pool.tier,
                pool.ticketPrice,
                pool.maxTicketsPerWallet,
                pool.ticketsSold,
                pool.prizeCount,
                pool.entries.length
            );
    }

    function getPrizes(uint256 raffleId, uint256 poolId) external view returns (PrizeLine[] memory) {
        return _pool(raffleId, poolId).prizes;
    }

    function getEntry(uint256 raffleId, uint256 poolId, uint256 entryId) external view returns (Entry memory) {
        Pool storage pool = _pool(raffleId, poolId);
        if (entryId >= pool.entries.length) revert InvalidEntry();
        return pool.entries[entryId];
    }

    function _claim(uint256 raffleId, uint256 poolId, Win[] calldata wins, address redirect) private {
        if (wins.length == 0) revert EmptyClaim();
        Pool storage pool = _pool(raffleId, poolId);
        // Group adjacent wins for the same wallet into one mintBatch; work and memory are O(wins).
        uint256 start;
        while (start < wins.length) {
            if (wins[start].entry >= pool.entries.length) revert InvalidEntry();
            address wallet = pool.entries[wins[start].entry].wallet;
            if (redirect != address(0) && msg.sender != wallet) revert NotEntryWallet();
            uint256 end = start + 1;
            while (
                end < wins.length && wins[end].entry < pool.entries.length
                    && pool.entries[wins[end].entry].wallet == wallet
            ) ++end;
            uint256[] memory ids = new uint256[](end - start);
            uint256[] memory amounts = new uint256[](end - start);
            address to = redirect == address(0) ? wallet : redirect;
            for (uint256 i = start; i < end; ++i) {
                ids[i - start] = _consumeWin(raffleId, poolId, wins[i]);
                amounts[i - start] = 1;
                emit PrizeClaimed(raffleId, poolId, wins[i].k, wallet, to, ids[i - start]);
            }
            furniture.mintBatch(to, ids, amounts);
            start = end;
        }
    }

    function _consumeWin(uint256 raffleId, uint256 poolId, Win calldata win) private returns (uint256 itemId) {
        uint256 ticket = winningTicket(raffleId, poolId, win.k);
        Entry storage entry = _pools[raffleId][poolId].entries[win.entry];
        if (ticket < entry.first || ticket >= entry.end) revert InvalidEntry();
        uint256 word = win.k >> 8;
        uint256 bit = uint256(1) << (win.k & 255);
        if (_claimed[raffleId][poolId][word] & bit != 0) revert AlreadyClaimed();
        _claimed[raffleId][poolId][word] |= bit;
        return prizeOf(raffleId, poolId, win.k);
    }

    function _checkWin(uint256 raffleId, uint256 poolId, uint256 k) private view {
        if (!_raffle(raffleId).drawn) revert NotDrawn();
        if (k >= winnerCount(raffleId, poolId)) revert InvalidWin();
    }

    function _key(uint256 raffleId, uint256 poolId, uint256 domain) private view returns (bytes32) {
        return keccak256(abi.encode(raffles[raffleId].seed, block.chainid, address(this), raffleId, poolId, domain));
    }

    function _raffle(uint256 raffleId) private view returns (Raffle storage raffle) {
        if (raffleId == 0 || raffleId > raffleCount) revert InvalidRaffle();
        raffle = raffles[raffleId];
        if (raffle.cancelled) revert RaffleCancelled();
    }

    function _pool(uint256 raffleId, uint256 poolId) private view returns (Pool storage pool) {
        if (poolId >= _raffle(raffleId).poolCount) revert InvalidPool();
        return _pools[raffleId][poolId];
    }
}
