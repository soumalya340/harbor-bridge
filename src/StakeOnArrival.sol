// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IStakeOnArrival} from "./interfaces/IStakeOnArrival.sol";
import {IHarborStaking} from "./interfaces/IHarborStaking.sol";
import {Message} from "./interfaces/IHarborBridge.sol";

interface IFailedHookBridge {
    function consumeFailedHook(Message calldata message) external;
}

interface IHarborPoolInfo {
    function poolInfo(uint256 pid) external view
        returns (address stakingToken, uint256, uint256, uint256, uint256, uint256);
}

/// @notice Stakes first deposits for self-directed EOAs; safely delivers all other arrivals.
contract StakeOnArrival is IStakeOnArrival, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable bridge;
    IERC20 public immutable wrappedToken;
    IHarborStaking public immutable staking;
    uint256 public immutable pid;

    event Arrival(address indexed beneficiary, uint256 staked, uint256 liquid);

    constructor(address bridge_, address wrappedToken_, address staking_, uint256 pid_) {
        require(bridge_.code.length > 0 && wrappedToken_.code.length > 0 && staking_.code.length > 0, "invalid contract");
        bridge = bridge_;
        wrappedToken = IERC20(wrappedToken_);
        staking = IHarborStaking(staking_);
        pid = pid_;
        // The staking team may add the pool/approve the operator after deployment.
    }

    function onBridgeReceived(uint256, address sender, uint256 amount, bytes calldata hookData)
        external nonReentrant
    {
        require(msg.sender == bridge && sender != address(0) && amount > 0, "invalid arrival");
        address beneficiary = _beneficiary(sender, hookData);
        require(wrappedToken.balanceOf(address(this)) >= amount, "missing mint");
        if (beneficiary != sender || beneficiary.code.length != 0) {
            _deliver(beneficiary, amount);
            return;
        }

        // A self-call makes staking, verification, approvals and payout atomic. If any
        // part fails, all staking effects roll back before we deliver liquid tokens.
        // Keep enough gas outside the attempt to perform a fallback transfer.
        if (gasleft() < 100_000) {
            _deliver(beneficiary, amount);
            return;
        }
        try this.attemptStake{gas: gasleft() - 70_000}(beneficiary, amount) {} catch {
            _deliver(beneficiary, amount);
        }
    }

    function attemptStake(address beneficiary, uint256 amount) external {
        require(msg.sender == address(this), "only self");
        (address poolToken,,,,,) = IHarborPoolInfo(address(staking)).poolInfo(pid);
        require(poolToken == address(wrappedToken), "wrong pool token");
        // Deposits reset the entire account's seven-day lock. Do not let delayed arrivals
        // or third parties postpone withdrawal of an existing position.
        require(staking.stakedAmount(pid, beneficiary) == 0, "existing stake");
        uint256 balanceBefore = wrappedToken.balanceOf(address(this));
        wrappedToken.forceApprove(address(staking), amount);
        staking.deposit(pid, amount, beneficiary);
        wrappedToken.forceApprove(address(staking), 0);

        uint256 deposited = staking.stakedAmount(pid, beneficiary);
        require(deposited > 0 && deposited <= amount, "incorrect stake credit");
        // Deposits can be capped and can pay existing rewards to the operator. Use
        // credited stake to measure principal, then return both remainder and rewards.
        uint256 balanceAfter = wrappedToken.balanceOf(address(this));
        require(balanceAfter >= balanceBefore - deposited, "incorrect token spend");
        uint256 liquid = balanceAfter - (balanceBefore - amount);
        if (liquid != 0) wrappedToken.safeTransfer(beneficiary, liquid);
        emit Arrival(beneficiary, deposited, liquid);
    }

    /// @notice Anyone can finish a failed/OOG arrival, but its authenticated beneficiary
    /// is fixed by the original message. Works even after the bridge is paused/rotated.
    function recoverFailed(Message calldata message) external nonReentrant {
        require(message.recipient == address(this), "wrong receiver");
        IFailedHookBridge(bridge).consumeFailedHook(message);
        _deliver(_beneficiary(message.sender, message.hookData), message.amount / 1e12);
    }

    function _deliver(address beneficiary, uint256 amount) private {
        wrappedToken.safeTransfer(beneficiary, amount);
        emit Arrival(beneficiary, 0, amount);
    }

    function _beneficiary(address sender, bytes calldata data) private view returns (address beneficiary) {
        // Invalid hook data is recoverable to the authenticated source sender.
        if (data.length == 32) {
            uint256 word;
            assembly ("memory-safe") { word := calldataload(data.offset) }
            if (word <= type(uint160).max) beneficiary = address(uint160(word));
        }
        if (beneficiary == address(0) || beneficiary == address(this)
            || beneficiary == bridge || beneficiary == address(wrappedToken) || beneficiary == address(staking)) {
            beneficiary = sender;
        }
        require(beneficiary != address(0) && beneficiary != address(this)
            && beneficiary != bridge && beneficiary != address(wrappedToken) && beneficiary != address(staking),
            "unsafe beneficiary");
    }
}
