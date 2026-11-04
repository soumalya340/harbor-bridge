// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHarborBridge, Message} from "./interfaces/IHarborBridge.sol";

/// @notice Shared authentication and replay protection for a single remote chain.
abstract contract BridgeBase is IHarborBridge, ReentrancyGuard {
    uint256 public constant SCALE = 1e12; // HBR has 18 decimals; wHBR has 6.
    uint256 public constant MAX_HOOK_GAS = 2_000_000;
    uint256 public constant MAX_HOOK_DATA = 4096;
    uint256 public constant MAX_VALIDATORS = 64;

    address public immutable token;
    address public immutable admin;
    uint256 public immutable localChainId;
    uint256 public immutable remoteChainId;
    uint256 public threshold;
    uint256 public validatorEpoch;
    uint256 public nextNonce;
    bool public paused;
    address[] public validators;
    mapping(address => bool) public isValidator;
    mapping(uint256 => bool) public processed;

    event ValidatorsChanged(uint256 indexed epoch, address[] validators, uint256 threshold);
    event PauseChanged(bool paused);
    event MessageExecuted(bytes32 indexed messageId, uint256 indexed nonce);

    constructor(address token_, uint256 remoteChainId_, address[] memory validators_, uint256 threshold_, address admin_) {
        require(token_.code.length != 0 && admin_ != address(0), "invalid address");
        require(remoteChainId_ != 0 && remoteChainId_ != block.chainid, "invalid remote chain");
        token = token_;
        admin = admin_;
        localChainId = block.chainid;
        remoteChainId = remoteChainId_;
        _setValidators(validators_, threshold_);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    modifier active() {
        require(!paused && block.chainid == localChainId, "inactive");
        _;
    }

    function setPaused(bool value) external onlyAdmin nonReentrant {
        paused = value;
        emit PauseChanged(value);
    }

    function setValidators(address[] calldata newValidators, uint256 newThreshold)
        external onlyAdmin nonReentrant
    {
        _setValidators(newValidators, newThreshold);
    }

    function _setValidators(address[] memory newValidators, uint256 newThreshold) private {
        require(newValidators.length <= MAX_VALIDATORS, "too many validators");
        require(newThreshold > 0 && newThreshold <= newValidators.length, "invalid threshold");
        for (uint256 i; i < validators.length; ++i) isValidator[validators[i]] = false;
        for (uint256 i; i < newValidators.length; ++i) {
            address validator = newValidators[i];
            require(validator != address(0) && !isValidator[validator], "invalid validator");
            isValidator[validator] = true;
        }
        validators = newValidators;
        threshold = newThreshold;
        ++validatorEpoch;
        emit ValidatorsChanged(validatorEpoch, newValidators, newThreshold);
    }

    /// @dev Raw ECDSA digest, without personal_sign or an Ethereum signed-message prefix.
    /// Epoch rotation invalidates pending signatures, but not message identity/replay state.
    function messageDigest(Message calldata message) public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("HARBOR_BRIDGE_V1"), localChainId, address(this), token,
            remoteChainId, validatorEpoch, _messageId(message)
        ));
    }

    function _messageId(Message memory message) internal pure returns (bytes32) {
        return keccak256(abi.encode(message));
    }

    function _authenticate(Message calldata message, bytes[] calldata signatures) internal returns (bytes32 id) {
        require(message.srcChainId == remoteChainId && message.dstChainId == localChainId, "wrong route");
        require(message.sender != address(0), "zero sender");
        _checkRecipient(message.recipient);
        require(message.amount > 0 && message.amount % SCALE == 0, "invalid amount");
        require(!processed[message.nonce], "already processed");
        require(signatures.length >= threshold && signatures.length <= validators.length, "signature count");
        bytes32 digest = messageDigest(message);
        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            require(signatures[i].length == 65, "signature length");
            address signer = ECDSA.recover(digest, signatures[i]);
            require(isValidator[signer] && signer > previous, "invalid signer/order");
            previous = signer;
        }
        processed[message.nonce] = true;
        id = _messageId(message);
        emit MessageExecuted(id, message.nonce);
    }

    function _checkRecipient(address recipient) internal view {
        require(recipient != address(0) && recipient != address(this) && recipient != token, "invalid recipient");
    }

    function _checkOutbound(uint256 dstChainId, address recipient, uint256 amount) internal view {
        require(dstChainId == remoteChainId && amount > 0, "invalid transfer");
        _checkRecipient(recipient);
    }

    function _checkHook(uint256 gasLimit, bytes memory data) internal pure {
        require(gasLimit <= MAX_HOOK_GAS && data.length <= MAX_HOOK_DATA, "hook too large");
        require(gasLimit != 0 || data.length == 0, "hook needs gas");
    }

    function _send(address recipient, uint256 amount, uint256 gasLimit, bytes memory data)
        internal returns (bytes32 id)
    {
        Message memory message = Message({
            srcChainId: localChainId, dstChainId: remoteChainId, nonce: nextNonce++,
            sender: msg.sender, recipient: recipient, amount: amount, hookGasLimit: gasLimit, hookData: data
        });
        id = _messageId(message);
        emit MessageSent(id, message);
    }
}
