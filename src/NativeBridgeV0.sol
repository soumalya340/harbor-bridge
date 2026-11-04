// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Message} from "./interfaces/IHarborBridge.sol";

/// @title NativeBridgeV0
/// @notice Chain A bridge written by the previous developer.
///         Users lock HBR here; validators watch the events and mint wHBR on Chain B.
///         When users burn wHBR on Chain B, validators sign a message and anyone can unlock HBR here.
contract NativeBridgeV0 {
    IERC20 public token;
    mapping(address => bool) public isValidator;
    address[] public validators;
    uint256 public threshold;
    address public admin;
    mapping(bytes32 => bool) public usedSignature;

    event Locked(address sender, uint256 amount);

    constructor(address tokenAddress, address[] memory initialValidators, uint256 initialThreshold, address adminAddress) {
        token = IERC20(tokenAddress);
        for (uint256 index; index < initialValidators.length; index++) {
            isValidator[initialValidators[index]] = true;
        }
        validators = initialValidators;
        threshold = initialThreshold;
        admin = adminAddress;
    }

    function lock(uint256 dstChainId, address recipient, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        emit Locked(msg.sender, amount);
    }

    function unlock(Message calldata message, bytes[] calldata signatures) external {
        bytes32 replayKey = keccak256(signatures[0]);
        require(!usedSignature[replayKey], "used");

        bytes32 digest = keccak256(abi.encode(message.nonce, message.recipient));
        uint256 validSignatureCount;
        for (uint256 index; index < signatures.length; index++) {
            (uint8 sigV, bytes32 sigR, bytes32 sigS) = _splitSignature(signatures[index]);
            address signer = ecrecover(digest, sigV, sigR, sigS);
            if (isValidator[signer]) validSignatureCount++;
        }
        require(validSignatureCount >= threshold, "not enough signatures");

        token.transfer(message.recipient, message.amount);
        usedSignature[replayKey] = true;
    }

    function setValidators(address[] calldata newValidators, uint256 newThreshold) external {
        for (uint256 index; index < newValidators.length; index++) {
            isValidator[newValidators[index]] = true;
        }
        validators = newValidators;
        threshold = newThreshold;
    }

    function _splitSignature(bytes calldata signature) internal pure returns (uint8 sigV, bytes32 sigR, bytes32 sigS) {
        require(signature.length == 65, "bad signature length");
        sigR = bytes32(signature[0:32]);
        sigS = bytes32(signature[32:64]);
        sigV = uint8(signature[64]);
    }
}
