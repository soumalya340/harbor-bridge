// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {HarborToken} from "../src/token/HarborToken.sol";
import {WrappedHarbor} from "../src/token/WrappedHarbor.sol";
import {INativeBridge, IWrappedBridge, IHarborBridge, Message} from "../src/interfaces/IHarborBridge.sol";
import {IHarborStaking} from "../src/interfaces/IHarborStaking.sol";
import {HarborStaking} from "../src/staking/HarborStaking.sol";

/// @notice Public smoke tests. They only check that your contracts match the fixed interface
///         and that the happy path works. Passing them says nothing about security.
///
///         Both chains are simulated in one EVM by switching `block.chainid` with `vm.chainId`.
///         Your contracts must live at src/NativeBridge.sol, src/WrappedBridge.sol and src/StakeOnArrival.sol,
///         and must work right after the fixed constructor.
///         Do not modify this file.
contract PublicTest is Test {
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

    function setUp() public {
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

    /// A -> B -> A round trip
    function test_RoundTrip() public {
        uint256 startBalance = token.balanceOf(alice);
        vm.chainId(CHAIN_A);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), 100 ether);
        vm.recordLogs();
        nativeBridge.lock(CHAIN_B, alice, 100 ether);
        vm.stopPrank();
        (, Message memory lockMessage) = _lastMessageSent();

        vm.chainId(CHAIN_B);
        wrappedBridge.mint(lockMessage, _sign(lockMessage, wrappedBridge));
        uint256 minted = wrappedToken.balanceOf(alice);
        assertGt(minted, 0);

        vm.prank(alice);
        vm.recordLogs();
        wrappedBridge.burn(CHAIN_A, alice, minted);
        (, Message memory burnMessage) = _lastMessageSent();
        assertEq(wrappedToken.balanceOf(alice), 0);

        vm.chainId(CHAIN_A);
        nativeBridge.unlock(burnMessage, _sign(burnMessage, nativeBridge));
        assertGt(token.balanceOf(alice), startBalance - 100 ether); // got HBR back (the token fee is not refunded)
    }

    /// Lock on A with a hook → mint on B → staked for the beneficiary
    function test_BridgeAndStake() public {
        vm.chainId(CHAIN_B);
        IHarborStaking staking = IHarborStaking(
            address(new HarborStaking(address(wrappedToken), 1 ether, block.timestamp, block.timestamp + 30 days, admin))
        );
        address stakeOnArrival = deployCode(
            "StakeOnArrival.sol:StakeOnArrival",
            abi.encode(address(wrappedBridge), address(wrappedToken), address(staking), 0)
        );
        vm.startPrank(admin); // the staking team
        staking.add(100, address(wrappedToken));
        staking.setOperator(stakeOnArrival, true);
        vm.stopPrank();

        vm.chainId(CHAIN_A);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), 100 ether);
        vm.recordLogs();
        nativeBridge.lockWithHook(CHAIN_B, stakeOnArrival, 100 ether, 500_000, abi.encode(alice));
        vm.stopPrank();
        (, Message memory message) = _lastMessageSent();

        vm.chainId(CHAIN_B);
        wrappedBridge.mint(message, _sign(message, wrappedBridge));
        assertGt(staking.stakedAmount(0, alice), 0);
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
