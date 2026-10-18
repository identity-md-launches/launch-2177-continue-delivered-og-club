// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Unlocked OG staking with nontransferable points. No owner custody or points adjustment functions.
contract OGClubStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant UNSTAKE_FEE_BPS = 100;
    uint256 public constant SPENDER_DELAY = 7 days;
    uint256 public constant MAX_POINTS_PER_TOKEN_DAY = type(uint96).max;
    IERC20 public immutable token;
    address public immutable vault;
    uint256 public immutable pointsPerTokenDay;

    /// @dev Two slots: balance/time/fraction in one, whole point-wei in the other.
    ///      Keeping the fraction makes checkpoint frequency irrelevant, even for 1-wei stakes.
    struct Account {
        uint128 balance;
        uint48 updatedAt;
        uint80 remainder;
        uint256 points;
    }

    mapping(address => Account) public accounts;
    uint256 public totalStaked;
    /// @notice 86400 * 10**token.decimals(), fixed on first stake. Supports 0 through 18 decimals.
    /// @dev Read on first use so factory constructors never call dependencies.
    uint80 public accrualDenominator;
    bool public bootstrapped;
    mapping(address => bool) public spenders;
    mapping(address => uint256) public pendingSpenders;

    error InvalidAddress();
    error InvalidRate();
    error UnsupportedDecimals();
    error ZeroAmount();
    error InsufficientStake();
    error InsufficientPoints();
    error UnexpectedTokenDebit();
    error NotSpender();
    error NoSpenderProposal(address spender);
    error SpenderDelayNotElapsed(address spender, uint256 activatesAt);

    event Staked(address indexed account, uint256 received);
    event Unstaked(address indexed account, uint256 amount, uint256 fee);
    event PointsSpent(address indexed account, address indexed spender, uint256 amount);
    event SpenderSet(address indexed spender, bool allowed);
    event SpenderProposed(address indexed spender, uint256 activatesAt);
    event SpenderProposalCancelled(address indexed spender);

    constructor(IERC20 token_, address vault_, address initialOwner, uint256 pointsPerTokenDay_) Ownable(initialOwner) {
        if (address(token_) == address(0) || vault_ == address(0) || vault_ == address(this)) revert InvalidAddress();
        if (pointsPerTokenDay_ == 0 || pointsPerTokenDay_ > MAX_POINTS_PER_TOKEN_DAY) revert InvalidRate();
        token = token_;
        vault = vault_;
        pointsPerTokenDay = pointsPerTokenDay_;
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (accrualDenominator == 0) {
            uint8 decimals = IERC20Metadata(address(token)).decimals();
            if (decimals > 18) revert UnsupportedDecimals();
            accrualDenominator = uint80(1 days * 10 ** uint256(decimals));
        }
        _accrue(msg.sender);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert ZeroAmount();
        Account storage account = accounts[msg.sender];
        account.balance = (uint256(account.balance) + received).toUint128();
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Account storage account = accounts[msg.sender];
        if (amount > account.balance) revert InsufficientStake();
        _accrue(msg.sender);
        account.balance -= uint128(amount);
        totalStaked -= amount;
        uint256 fee = Math.ceilDiv(amount, 10_000 / UNSTAKE_FEE_BPS);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransfer(vault, fee);
        if (amount > fee) token.safeTransfer(msg.sender, amount - fee);
        if (token.balanceOf(address(this)) != beforeBalance - amount) revert UnexpectedTokenDebit();
        emit Unstaked(msg.sender, amount, fee);
    }

    function pointsOf(address account) public view returns (uint256) {
        (uint256 points,) = _pending(accounts[account]);
        return points;
    }

    function stakeOf(address account) external view returns (uint256) {
        return accounts[account].balance;
    }

    /// @notice Only authorized game contracts can consume points. Ownership itself gives no spending right.
    function spendPoints(address account, uint256 amount) external nonReentrant {
        if (!spenders[msg.sender]) revert NotSpender();
        _accrue(account);
        if (amount > accounts[account].points) revert InsufficientPoints();
        accounts[account].points -= amount;
        emit PointsSpent(account, msg.sender, amount);
    }

    function grantSpender(address spender) external onlyOwner {
        if (spender == address(0)) revert InvalidAddress();
        if (!bootstrapped) {
            bootstrapped = true;
            delete pendingSpenders[spender];
            spenders[spender] = true;
            emit SpenderSet(spender, true);
        } else {
            uint256 activatesAt = block.timestamp + SPENDER_DELAY;
            pendingSpenders[spender] = activatesAt;
            emit SpenderProposed(spender, activatesAt);
        }
    }

    /// @notice Anyone may activate in the inclusive interval [proposal + 7 days, proposal + 14 days].
    function activateSpender(address spender) external {
        uint256 activatesAt = pendingSpenders[spender];
        if (activatesAt == 0 || block.timestamp > activatesAt + SPENDER_DELAY) revert NoSpenderProposal(spender);
        if (block.timestamp < activatesAt) revert SpenderDelayNotElapsed(spender, activatesAt);
        delete pendingSpenders[spender];
        spenders[spender] = true;
        emit SpenderSet(spender, true);
    }

    function cancelSpender(address spender) external onlyOwner {
        uint256 activatesAt = pendingSpenders[spender];
        if (activatesAt == 0 || block.timestamp > activatesAt + SPENDER_DELAY) revert NoSpenderProposal(spender);
        delete pendingSpenders[spender];
        emit SpenderProposalCancelled(spender);
    }

    function revokeSpender(address spender) external onlyOwner {
        if (spender == address(0)) revert InvalidAddress();
        delete pendingSpenders[spender];
        spenders[spender] = false;
        emit SpenderSet(spender, false);
    }

    function _accrue(address who) private {
        Account storage account = accounts[who];
        (account.points, account.remainder) = _pending(account);
        account.updatedAt = block.timestamp.toUint48();
    }

    function _pending(Account memory account) private view returns (uint256 points, uint80 remainder) {
        points = account.points;
        remainder = account.remainder;
        if (account.balance == 0) return (points, remainder);
        // Both time and rate are bounded, so this intermediate fits in 144 bits.
        uint256 factor = (uint256(block.timestamp.toUint48()) - account.updatedAt) * pointsPerTokenDay;
        uint256 denominator = accrualDenominator;
        points += Math.mulDiv(account.balance, factor, denominator);
        uint256 fraction = mulmod(account.balance, factor, denominator) + remainder;
        points += fraction / denominator;
        remainder = uint80(fraction % denominator);
    }
}
