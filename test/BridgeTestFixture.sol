// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {HarborToken} from "../src/token/HarborToken.sol";
import {WrappedHarbor} from "../src/token/WrappedHarbor.sol";
import {INativeBridge, IWrappedBridge, IHarborBridge, Message} from "../src/interfaces/IHarborBridge.sol";
import {IHarborStaking} from "../src/interfaces/IHarborStaking.sol";
import {HarborStaking} from "../src/staking/HarborStaking.sol";

/// @notice Shared fixture for adversarial tests; all bridge operations use the fixed interfaces.
abstract contract BridgeTestFixture is Test {
    uint256 internal constant CHAIN_A = 8453200012;
    uint256 internal constant CHAIN_B = 1002;
    uint256 internal constant THRESHOLD = 2;

    bytes32 internal constant MESSAGE_SENT_TOPIC =
        keccak256("MessageSent(bytes32,(uint256,uint256,uint256,address,address,uint256,uint256,bytes))");

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    uint256[] internal validatorKeys; // sorted by validator address, ascending
    address[] internal validatorAddresses;

    HarborToken internal token;
    WrappedHarbor internal wrappedToken;
    INativeBridge internal nativeBridge;
    IWrappedBridge internal wrappedBridge;

    function setUp() public virtual {
        _createValidators(3);

        vm.chainId(CHAIN_A);
        token = new HarborToken(admin, admin);
        nativeBridge = INativeBridge(
            deployCode(
                "NativeBridge.sol:NativeBridge", abi.encode(address(token), CHAIN_B, validatorAddresses, THRESHOLD, admin)
            )
        );

        vm.chainId(CHAIN_B);
        wrappedToken = new WrappedHarbor(admin);
        wrappedBridge = IWrappedBridge(
            deployCode(
                "WrappedBridge.sol:WrappedBridge",
                abi.encode(address(wrappedToken), CHAIN_A, validatorAddresses, THRESHOLD, admin)
            )
        );
        vm.prank(admin);
        wrappedToken.setBridge(address(wrappedBridge));

        vm.prank(admin);
        token.transfer(alice, 1_000 ether);
    }

    // ───────── helpers ─────────

    function _createValidators(uint256 count) internal {
        for (uint256 index; index < count; index++) {
            uint256 key = uint256(keccak256(abi.encode("validator", index)));
            validatorKeys.push(key);
            validatorAddresses.push(vm.addr(key));
        }
        // insertion sort by address, ascending
        for (uint256 outer = 1; outer < count; outer++) {
            for (uint256 inner = outer; inner > 0 && validatorAddresses[inner - 1] > validatorAddresses[inner]; inner--) {
                (validatorAddresses[inner - 1], validatorAddresses[inner]) =
                    (validatorAddresses[inner], validatorAddresses[inner - 1]);
                (validatorKeys[inner - 1], validatorKeys[inner]) = (validatorKeys[inner], validatorKeys[inner - 1]);
            }
        }
    }

    function _lastMessageSent() internal returns (bytes32 messageId, Message memory message) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index = logs.length; index > 0; index--) {
            Vm.Log memory entry = logs[index - 1];
            if (entry.topics.length > 0 && entry.topics[0] == MESSAGE_SENT_TOPIC) {
                return (entry.topics[1], abi.decode(entry.data, (Message)));
            }
        }
        revert("MessageSent not emitted");
    }

    /// Signs `messageDigest(message)` of the destination bridge with the first THRESHOLD validators,
    /// in ascending address order.
    function _sign(Message memory message, IHarborBridge destinationBridge)
        internal
        view
        returns (bytes[] memory signatures)
    {
        bytes32 digest = destinationBridge.messageDigest(message);
        signatures = new bytes[](THRESHOLD);
        for (uint256 index; index < THRESHOLD; index++) {
            (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(validatorKeys[index], digest);
            signatures[index] = abi.encodePacked(sigR, sigS, sigV);
        }
    }
}
