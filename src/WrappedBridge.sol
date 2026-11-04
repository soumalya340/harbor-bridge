// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {WrappedHarbor} from "./token/WrappedHarbor.sol";
import {IWrappedBridge, IBridgeHookReceiver, Message} from "./interfaces/IHarborBridge.sol";
import {BridgeBase} from "./BridgeBase.sol";

contract WrappedBridge is BridgeBase, IWrappedBridge {
    mapping(bytes32 => bool) public failedHooks;
    event HookResult(bytes32 indexed messageId, bool success);
    event FailedHookConsumed(bytes32 indexed messageId);

    constructor(address token_, uint256 remoteChainId_, address[] memory validators_, uint256 threshold_, address admin_)
        BridgeBase(token_, remoteChainId_, validators_, threshold_, admin_)
    {
        require(WrappedHarbor(token_).decimals() == 6, "wrong decimals");
    }

    function burn(uint256 dstChainId, address recipient, uint256 amount)
        external active nonReentrant returns (bytes32)
    {
        _checkOutbound(dstChainId, recipient, amount);
        // The burn argument is in local wHBR units; the wire always uses HBR units.
        uint256 wireAmount = amount * SCALE;
        WrappedHarbor(token).bridgeBurn(msg.sender, amount);
        return _send(recipient, wireAmount, 0, "");
    }

    function mint(Message calldata message, bytes[] calldata signatures) external active nonReentrant {
        _checkHook(message.hookGasLimit, message.hookData);
        bytes32 id = _authenticate(message, signatures);
        WrappedHarbor(token).bridgeMint(message.recipient, message.amount / SCALE);
        if (message.hookGasLimit != 0) {
            bool success = _callHook(message, message.hookGasLimit);
            if (!success) failedHooks[id] = true;
            emit HookResult(id, success);
        }
    }

    /// @notice Retry without minting again; extra gas can repair an undersized sender budget.
    /// Failure leaves the claim recoverable. Validator rotation/pause do not trap minted funds.
    function retryHook(Message calldata message, uint256 gasLimit) external nonReentrant {
        require(block.chainid == localChainId, "wrong chain");
        bytes32 id = _messageId(message);
        require(failedHooks[id] && gasLimit > 0 && gasLimit <= MAX_HOOK_GAS, "invalid retry");
        failedHooks[id] = false;
        bool success = _callHook(message, gasLimit);
        if (!success) failedHooks[id] = true;
        emit HookResult(id, success);
    }

    /// @notice Receiver-authenticated acknowledgement for a receiver's own recovery path.
    /// No token movement here: the initial mint remains at the receiver after a reverted hook.
    function consumeFailedHook(Message calldata message) external nonReentrant {
        require(block.chainid == localChainId && msg.sender == message.recipient, "not receiver");
        bytes32 id = _messageId(message);
        require(failedHooks[id], "no failed hook");
        failedHooks[id] = false;
        emit FailedHookConsumed(id);
    }

    function _callHook(Message calldata message, uint256 gasLimit) private returns (bool success) {
        bytes memory payload = abi.encodeCall(IBridgeHookReceiver.onBridgeReceived,
            (message.srcChainId, message.sender, message.amount / SCALE, message.hookData));
        address recipient = message.recipient;
        if (recipient.code.length == 0) return false;
        // Cover EIP-150's 1/64 retention, CALL overhead, and failure bookkeeping.
        // Relayer underfunding reverts the whole mint instead of manufacturing a hook failure.
        require(gasleft() >= gasLimit + gasLimit / 63 + 80_000, "insufficient relay gas");
        assembly ("memory-safe") {
            // Never copy arbitrary return data (including revert-data bombs).
            success := call(gasLimit, recipient, 0, add(payload, 32), mload(payload), 0, 0)
        }
    }
}
