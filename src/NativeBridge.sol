// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HarborToken} from "./token/HarborToken.sol";
import {INativeBridge, Message} from "./interfaces/IHarborBridge.sol";
import {BridgeBase} from "./BridgeBase.sol";

/// @notice Net-denominated HBR bridge with collateral for the token's maximum exit fee.
contract NativeBridge is BridgeBase, INativeBridge {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 public immutable maxFeeBps;
    uint256 public outstanding;
    uint256 public totalRefundCredit;
    mapping(address => uint256) public refundCredit;

    event RefundAccrued(address indexed account, uint256 grossAmount);
    event RefundClaimed(address indexed account, address indexed to, uint256 grossAmount);

    constructor(address token_, uint256 remoteChainId_, address[] memory validators_, uint256 threshold_, address admin_)
        BridgeBase(token_, remoteChainId_, validators_, threshold_, admin_)
    {
        require(HarborToken(token_).decimals() == 18, "wrong decimals");
        maxFeeBps = HarborToken(token_).MAX_FEE_BPS();
        require(maxFeeBps < BPS, "invalid maximum fee");
    }

    /// @return amount Net HBR liability, also the 18-decimal amount emitted for minting.
    /// @return collateral Gross HBR backing, including the maximum possible exit fee.
    function quoteReceived(uint256 received) public view returns (uint256 amount, uint256 collateral) {
        amount = Math.mulDiv(received, BPS - maxFeeBps, BPS) / SCALE * SCALE;
        collateral = Math.mulDiv(amount, BPS, BPS - maxFeeBps, Math.Rounding.Ceil);
    }

    function lock(uint256 dstChainId, address recipient, uint256 amount)
        external active nonReentrant returns (bytes32)
    {
        return _lock(dstChainId, recipient, amount, 0, "", 0);
    }

    /// @notice Optional slippage protection against a fee change before inclusion.
    function lock(uint256 dstChainId, address recipient, uint256 amount, uint256 minimumNetAmount)
        external active nonReentrant returns (bytes32)
    {
        return _lock(dstChainId, recipient, amount, 0, "", minimumNetAmount);
    }

    function lockWithHook(uint256 dstChainId, address recipient, uint256 amount, uint256 hookGasLimit, bytes calldata hookData)
        external active nonReentrant returns (bytes32)
    {
        return _lock(dstChainId, recipient, amount, hookGasLimit, hookData, 0);
    }

    function lockWithHook(
        uint256 dstChainId, address recipient, uint256 amount, uint256 hookGasLimit,
        bytes calldata hookData, uint256 minimumNetAmount
    ) external active nonReentrant returns (bytes32) {
        return _lock(dstChainId, recipient, amount, hookGasLimit, hookData, minimumNetAmount);
    }

    function _lock(uint256 dstChainId, address recipient, uint256 amount, uint256 gasLimit, bytes memory data, uint256 minimum)
        private returns (bytes32)
    {
        _checkOutbound(dstChainId, recipient, amount);
        _checkHook(gasLimit, data);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - beforeBalance;
        (uint256 net, uint256 collateral) = quoteReceived(received);
        require(net > 0 && net >= minimum, "net amount too small");
        outstanding += net;
        _credit(msg.sender, received - collateral);
        return _send(recipient, net, gasLimit, data);
    }

    function unlock(Message calldata message, bytes[] calldata signatures) external active nonReentrant {
        require(message.hookGasLimit == 0 && message.hookData.length == 0, "return hook forbidden");
        _authenticate(message, signatures);
        require(message.amount <= outstanding, "exceeds liabilities");
        outstanding -= message.amount;

        HarborToken harbor = HarborToken(token);
        uint256 fee = harbor.feeBps();
        require(fee <= maxFeeBps, "unsupported fee");
        // Minimal gross that transfers exactly `amount` net, including fee rounding.
        uint256 gross = message.recipient == harbor.feeCollector()
            ? message.amount
            : Math.mulDiv(message.amount - 1, BPS, BPS - fee) + 1;
        uint256 beforeRecipient = harbor.balanceOf(message.recipient);
        uint256 beforeBridge = harbor.balanceOf(address(this));
        IERC20(token).safeTransfer(message.recipient, gross);
        require(harbor.balanceOf(message.recipient) - beforeRecipient == message.amount, "wrong net payout");
        uint256 spent = beforeBridge - harbor.balanceOf(address(this));
        // Round down per redemption so splitting a burn cannot extract rounding dust.
        uint256 releasedReserve = Math.mulDiv(message.amount, BPS, BPS - maxFeeBps);
        _credit(message.recipient, releasedReserve - spent);
    }

    function _credit(address account, uint256 amount) private {
        if (amount == 0) return;
        refundCredit[account] += amount;
        totalRefundCredit += amount;
        emit RefundAccrued(account, amount);
    }

    /// @notice Claims gross HBR dust/unused fee reserve; the token charges its usual transfer fee.
    /// Available while paused. Only the credit owner chooses the payout address.
    function claimRefund(address to) external nonReentrant {
        require(block.chainid == localChainId, "wrong chain");
        _checkRecipient(to);
        uint256 amount = refundCredit[msg.sender];
        require(amount > 0, "no refund");
        refundCredit[msg.sender] = 0;
        totalRefundCredit -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit RefundClaimed(msg.sender, to, amount);
    }
}
