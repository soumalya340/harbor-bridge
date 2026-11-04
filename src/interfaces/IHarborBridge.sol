// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Fixed interface. Do NOT change anything in this file. See README.

struct Message {
    uint256 srcChainId;
    uint256 dstChainId;
    uint256 nonce;
    address sender;
    address recipient;
    uint256 amount;
    uint256 hookGasLimit;
    bytes hookData;
}

interface IBridgeHookReceiver {
    function onBridgeReceived(uint256 srcChainId, address sender, uint256 amount, bytes calldata hookData) external;
}

interface IHarborBridge {
    event MessageSent(bytes32 indexed messageId, Message message);

    function messageDigest(Message calldata message) external view returns (bytes32);

    function setValidators(address[] calldata newValidators, uint256 newThreshold) external;
}

interface INativeBridge is IHarborBridge {
    function lock(uint256 dstChainId, address recipient, uint256 amount) external returns (bytes32 messageId);
    function lockWithHook(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 hookGasLimit,
        bytes calldata hookData
    ) external returns (bytes32 messageId);
    function unlock(Message calldata message, bytes[] calldata signatures) external;
}

interface IWrappedBridge is IHarborBridge {
    function burn(uint256 dstChainId, address recipient, uint256 amount) external returns (bytes32 messageId);
    function mint(Message calldata message, bytes[] calldata signatures) external;
}
