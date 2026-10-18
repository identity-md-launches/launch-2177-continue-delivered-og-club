// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps;
    bool public senderFee;
    bool public returnFalse;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor(uint8 decimals_) ERC20("Test", "TST") {
        _decimals = decimals_;
    }

    function execute(address target, bytes calldata data) external {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureFee(uint256 bps, bool onSender) external {
        feeBps = bps;
        senderFee = onSender;
    }

    function configureFalse(bool value) external {
        returnFalse = value;
    }

    function configureCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        return super.transferFrom(from, to, value);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, address(0), fee);
            if (!senderFee) amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract NoReturnToken {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address to, uint256 amount) external {
        allowance[msg.sender][to] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
