// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PublicTest} from "./Public.t.sol";
import {NativeBridge} from "../src/NativeBridge.sol";
import {WrappedBridge} from "../src/WrappedBridge.sol";
import {BridgeBase} from "../src/BridgeBase.sol";
import {Message, IHarborBridge, IWrappedBridge, IBridgeHookReceiver} from "../src/interfaces/IHarborBridge.sol";
import {ITransferHook} from "../src/token/HarborToken.sol";

contract HostileHook is IBridgeHookReceiver {
    enum Mode { Revert, Exhaust, ReturnBomb, Reenter }
    Mode public mode;
    address public bridge;
    bool public reentrySucceeded;
    Message private savedMessage;
    bytes[] private savedSignatures;

    function configure(Mode mode_, address bridge_, Message calldata message, bytes[] calldata signatures) external {
        mode = mode_;
        bridge = bridge_;
        savedMessage = message;
        delete savedSignatures;
        for (uint256 i; i < signatures.length; ++i) savedSignatures.push(signatures[i]);
    }

    function onBridgeReceived(uint256, address, uint256, bytes calldata) external {
        if (mode == Mode.Revert) revert("hostile");
        if (mode == Mode.Exhaust) { assembly { for {} 1 {} {} } }
        if (mode == Mode.ReturnBomb) { assembly { revert(0, 0x100000) } }
        if (mode == Mode.Reenter) {
            (reentrySucceeded,) = bridge.call(abi.encodeCall(IWrappedBridge.mint, (savedMessage, savedSignatures)));
        }
    }
}

contract DepositReentry is ITransferHook {
    address public bridge;
    bytes public payload;
    bool public succeeded;
    function configure(address target, bytes calldata data) external { bridge = target; payload = data; }
    function onTokenSend(address, address, uint256) external { (succeeded,) = bridge.call(payload); }
}

contract BridgeSecurityTest is PublicTest {
    uint256 private constant CURVE_ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

    function _deposit(address recipient, uint256 amount, uint256 gasLimit, bytes memory data)
        internal returns (Message memory message)
    {
        vm.chainId(CHAIN_A);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), amount);
        vm.recordLogs();
        if (gasLimit == 0 && data.length == 0) nativeBridge.lock(CHAIN_B, recipient, amount);
        else nativeBridge.lockWithHook(CHAIN_B, recipient, amount, gasLimit, data);
        vm.stopPrank();
        (, message) = _lastMessageSent();
    }

    function _incoming() internal returns (Message memory message, bytes[] memory signatures) {
        message = _deposit(alice, 100 ether, 0, "");
        vm.chainId(CHAIN_B);
        signatures = _sign(message, wrappedBridge);
    }

    function _burn(address recipient, uint256 amount) internal returns (Message memory message) {
        vm.chainId(CHAIN_B);
        vm.prank(alice);
        vm.recordLogs();
        wrappedBridge.burn(CHAIN_A, recipient, amount);
        (, message) = _lastMessageSent();
    }

    function _signature(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _assertSolvent() internal view {
        NativeBridge native = NativeBridge(address(nativeBridge));
        uint256 required = (native.outstanding() * 10_000 + 9499) / 9500 + native.totalRefundCredit();
        assertGe(token.balanceOf(address(nativeBridge)), required);
    }

    function test_DuplicateSignaturesRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        signatures[1] = signatures[0];
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
        assertEq(wrappedToken.totalSupply(), 0);
    }

    function test_UnsortedSignaturesRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        (signatures[0], signatures[1]) = (signatures[1], signatures[0]);
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_InsufficientAndMalformedSignaturesRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        bytes[] memory one = new bytes[](1);
        one[0] = signatures[0];
        vm.expectRevert();
        wrappedBridge.mint(message, one);
        signatures[0] = hex"1234";
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_UnknownSignerRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        signatures[0] = _signature(12345, wrappedBridge.messageDigest(message));
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_AllSuppliedSignaturesMustBeValid() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        bytes[] memory extra = new bytes[](3);
        extra[0] = signatures[0];
        extra[1] = signatures[1];
        extra[2] = hex"00";
        vm.expectRevert();
        wrappedBridge.mint(message, extra);
        extra[2] = _signature(validatorKeys[2], wrappedBridge.messageDigest(message));
        wrappedBridge.mint(message, extra);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
    }

    function test_HighSSignatureRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorKeys[0], wrappedBridge.messageDigest(message));
        signatures[0] = abi.encodePacked(r, bytes32(CURVE_ORDER - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_PrefixedSignatureRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        bytes32 prefixed = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", wrappedBridge.messageDigest(message)));
        signatures[0] = _signature(validatorKeys[0], prefixed);
        signatures[1] = _signature(validatorKeys[1], prefixed);
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function testFuzz_EveryWireFieldIsAuthenticated(uint8 field) public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        field = uint8(bound(field, 0, 7));
        if (field == 0) ++message.srcChainId;
        if (field == 1) ++message.dstChainId;
        if (field == 2) ++message.nonce;
        if (field == 3) message.sender = makeAddr("other-sender");
        if (field == 4) message.recipient = makeAddr("other-recipient");
        if (field == 5) message.amount += 1e12;
        if (field == 6) message.hookGasLimit = 100_000;
        if (field == 7) { message.hookGasLimit = 100_000; message.hookData = hex"1234"; }
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_DeploymentDomainSeparation() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        WrappedBridge other = new WrappedBridge(address(wrappedToken), CHAIN_A, validatorAddresses, THRESHOLD, admin);
        assertNotEq(wrappedBridge.messageDigest(message), other.messageDigest(message));
        vm.expectRevert();
        other.mint(message, signatures);
    }

    function test_ReplayRejectedWithDifferentValidatorSubset() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        bytes32 digest = wrappedBridge.messageDigest(message);
        signatures[0] = _signature(validatorKeys[1], digest);
        signatures[1] = _signature(validatorKeys[2], digest);
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_ReplayNonceSurvivesChangedBodyAndRotation() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        vm.prank(admin);
        wrappedBridge.setValidators(validatorAddresses, THRESHOLD);
        message.amount += 1e12;
        signatures = _sign(message, wrappedBridge);
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
    }

    function test_ValidatorRotationRevokesOldSignaturesImmediately() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        address[] memory replacement = new address[](1);
        replacement[0] = vm.addr(1234);
        vm.prank(admin);
        wrappedBridge.setValidators(replacement, 1);
        assertFalse(WrappedBridge(address(wrappedBridge)).isValidator(validatorAddresses[0]));
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
        signatures = new bytes[](1);
        signatures[0] = _signature(1234, wrappedBridge.messageDigest(message));
        wrappedBridge.mint(message, signatures);
    }

    function test_RotatingToSameSetStillInvalidatesOldSignatures() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        vm.prank(admin);
        wrappedBridge.setValidators(validatorAddresses, THRESHOLD);
        vm.expectRevert();
        wrappedBridge.mint(message, signatures);
        wrappedBridge.mint(message, _sign(message, wrappedBridge));
    }

    function test_AdminOnlyAndInvalidValidatorConfigurations() public {
        vm.expectRevert();
        nativeBridge.setValidators(validatorAddresses, 1);
        vm.expectRevert();
        BridgeBase(address(nativeBridge)).setPaused(true);
        vm.startPrank(admin);
        vm.expectRevert();
        nativeBridge.setValidators(validatorAddresses, 0);
        vm.expectRevert();
        nativeBridge.setValidators(validatorAddresses, 4);
        address[] memory bad = new address[](2);
        bad[0] = validatorAddresses[0]; bad[1] = validatorAddresses[0];
        vm.expectRevert();
        nativeBridge.setValidators(bad, 2);
        bad[1] = address(0);
        vm.expectRevert();
        nativeBridge.setValidators(bad, 1);
        vm.stopPrank();
        assertEq(BridgeBase(address(nativeBridge)).threshold(), THRESHOLD);
    }

    function test_InvalidConstructorsRejected() public {
        vm.chainId(CHAIN_A);
        vm.expectRevert();
        new NativeBridge(address(0), CHAIN_B, validatorAddresses, 2, admin);
        vm.expectRevert();
        new NativeBridge(address(token), CHAIN_B, validatorAddresses, 2, address(0));
        vm.expectRevert();
        new NativeBridge(address(token), CHAIN_A, validatorAddresses, 2, admin);
        vm.expectRevert();
        new NativeBridge(address(token), 0, validatorAddresses, 2, admin);
        vm.expectRevert();
        new NativeBridge(address(token), CHAIN_B, validatorAddresses, 0, admin);
        vm.expectRevert();
        new WrappedBridge(address(token), CHAIN_B, validatorAddresses, 2, admin);
    }

    function test_InvalidOutboundAndDustCallsRevertWithoutTakingFunds() public {
        vm.chainId(CHAIN_A);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), type(uint256).max);
        vm.expectRevert(); nativeBridge.lock(CHAIN_A, alice, 1 ether);
        vm.expectRevert(); nativeBridge.lock(CHAIN_B, address(0), 1 ether);
        vm.expectRevert(); nativeBridge.lock(CHAIN_B, alice, 0);
        vm.expectRevert(); nativeBridge.lock(CHAIN_B, alice, 1);
        vm.expectRevert(); nativeBridge.lockWithHook(CHAIN_B, alice, 1 ether, 0, hex"01");
        vm.expectRevert(); nativeBridge.lockWithHook(CHAIN_B, alice, 1 ether, 2_000_001, hex"01");
        vm.expectRevert(); nativeBridge.lockWithHook(CHAIN_B, alice, 1 ether, 100_000, new bytes(4097));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), beforeBalance);
    }

    function test_ValidSignaturesDoNotBypassRoutingOrAmountChecks() public {
        (Message memory message,) = _incoming();
        message.srcChainId = CHAIN_B;
        bytes[] memory signatures = _sign(message, wrappedBridge);
        vm.expectRevert(); wrappedBridge.mint(message, signatures);
        message.srcChainId = CHAIN_A;
        message.amount = 1;
        signatures = _sign(message, wrappedBridge);
        vm.expectRevert(); wrappedBridge.mint(message, signatures);
        message.amount = 0;
        signatures = _sign(message, wrappedBridge);
        vm.expectRevert(); wrappedBridge.mint(message, signatures);
    }

    function test_PauseAndResume() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        vm.prank(admin); BridgeBase(address(wrappedBridge)).setPaused(true);
        vm.expectRevert(); wrappedBridge.mint(message, signatures);
        vm.prank(admin); BridgeBase(address(wrappedBridge)).setPaused(false);
        wrappedBridge.mint(message, signatures);
        vm.prank(admin); BridgeBase(address(wrappedBridge)).setPaused(true);
        vm.prank(alice);
        vm.expectRevert(); wrappedBridge.burn(CHAIN_A, alice, 1);
    }

    function test_OutOfOrderMessagesWork() public {
        Message memory first = _deposit(alice, 10 ether, 0, "");
        Message memory second = _deposit(alice, 20 ether, 0, "");
        assertEq(second.nonce, first.nonce + 1);
        vm.chainId(CHAIN_B);
        wrappedBridge.mint(second, _sign(second, wrappedBridge));
        wrappedBridge.mint(first, _sign(first, wrappedBridge));
        assertEq(wrappedToken.balanceOf(alice), (first.amount + second.amount) / 1e12);
    }

    function test_BurnOnlySpendsCallerAndUses18DecimalWireUnits() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        vm.expectRevert(); wrappedBridge.burn(CHAIN_A, address(this), 1);
        Message memory returned = _burn(alice, message.amount / 1e12);
        assertEq(returned.amount, message.amount);
        assertEq(returned.sender, alice);
        assertEq(returned.hookGasLimit, 0);
        assertEq(returned.hookData.length, 0);
    }

    function test_ReturnHooksRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        Message memory returned = _burn(alice, message.amount / 1e12);
        returned.hookGasLimit = 50_000;
        returned.hookData = hex"01";
        vm.chainId(CHAIN_A);
        signatures = _sign(returned, nativeBridge);
        vm.expectRevert(); nativeBridge.unlock(returned, signatures);
    }

    function test_NativeReplayAndAmountTamperingRejected() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        Message memory returned = _burn(alice, message.amount / 1e12);
        vm.chainId(CHAIN_A);
        signatures = _sign(returned, nativeBridge);
        returned.amount += 1e12;
        vm.expectRevert(); nativeBridge.unlock(returned, signatures);
        returned.amount -= 1e12;
        nativeBridge.unlock(returned, signatures);
        vm.expectRevert(); nativeBridge.unlock(returned, signatures);
    }

    function test_MinimumNetSlippageRevertsAtomically() public {
        vm.chainId(CHAIN_A);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), 100 ether);
        vm.expectRevert();
        NativeBridge(address(nativeBridge)).lock(CHAIN_B, alice, 100 ether, 100 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(address(nativeBridge)), 0);
        assertEq(NativeBridge(address(nativeBridge)).outstanding(), 0);
    }

    function testFuzz_FeeChangesPreserveExactNetPayoutAndSolvency(uint256 input, uint256 depositFee, uint256 exitFee) public {
        input = bound(input, 2e12, 900 ether);
        depositFee = bound(depositFee, 0, 500);
        exitFee = bound(exitFee, 0, 500);
        vm.prank(admin); token.setFee(depositFee);
        uint256 expectedReceived = input - input * depositFee / 10_000;
        (Message memory message, bytes[] memory signatures) = _incomingForAmount(input);
        assertEq(token.balanceOf(address(nativeBridge)), expectedReceived);
        assertEq(message.amount, expectedReceived * 9500 / 10_000 / 1e12 * 1e12);
        wrappedBridge.mint(message, signatures);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        _assertSolvent();
        Message memory returned = _burn(alice, message.amount / 1e12);
        vm.chainId(CHAIN_A);
        vm.prank(admin); token.setFee(exitFee);
        uint256 beforeBalance = token.balanceOf(alice);
        nativeBridge.unlock(returned, _sign(returned, nativeBridge));
        assertEq(token.balanceOf(alice) - beforeBalance, returned.amount);
        assertEq(NativeBridge(address(nativeBridge)).outstanding(), 0);
        _assertSolvent();
        if (NativeBridge(address(nativeBridge)).refundCredit(alice) > 0) {
            vm.prank(alice); NativeBridge(address(nativeBridge)).claimRefund(alice);
        }
        _assertSolvent();
    }

    function _incomingForAmount(uint256 amount) private returns (Message memory message, bytes[] memory signatures) {
        message = _deposit(alice, amount, 0, "");
        vm.chainId(CHAIN_B);
        signatures = _sign(message, wrappedBridge);
    }

    function testFuzz_SplitRedemptionsCannotDrainReserve(uint256 parts, uint256 fee) public {
        parts = bound(parts, 2, 16);
        fee = bound(fee, 0, 500);
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        uint256 chunk = wrappedToken.balanceOf(alice) / parts;
        vm.prank(admin); token.setFee(fee);
        for (uint256 i; i < parts; ++i) {
            Message memory returned = _burn(alice, i + 1 == parts ? wrappedToken.balanceOf(alice) : chunk);
            vm.chainId(CHAIN_A);
            nativeBridge.unlock(returned, _sign(returned, nativeBridge));
            if (NativeBridge(address(nativeBridge)).refundCredit(alice) > 0) {
                vm.prank(alice); NativeBridge(address(nativeBridge)).claimRefund(alice);
            }
            _assertSolvent();
        }
        assertEq(wrappedToken.totalSupply(), 0);
        assertEq(NativeBridge(address(nativeBridge)).outstanding(), 0);
    }

    function test_FeeCollectorReceivesExactNet() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        Message memory returned = _burn(admin, message.amount / 1e12);
        vm.chainId(CHAIN_A);
        uint256 beforeBalance = token.balanceOf(admin);
        nativeBridge.unlock(returned, _sign(returned, nativeBridge));
        assertEq(token.balanceOf(admin) - beforeBalance, returned.amount);
        _assertSolvent();
    }

    function test_RefundOwnershipAndClaimsWhilePaused() public {
        (Message memory message, bytes[] memory signatures) = _incoming();
        wrappedBridge.mint(message, signatures);
        Message memory returned = _burn(alice, message.amount / 1e12);
        vm.chainId(CHAIN_A);
        nativeBridge.unlock(returned, _sign(returned, nativeBridge));
        vm.prank(admin); NativeBridge(address(nativeBridge)).setPaused(true);
        vm.expectRevert(); NativeBridge(address(nativeBridge)).claimRefund(address(this));
        vm.prank(alice); NativeBridge(address(nativeBridge)).claimRefund(alice);
        vm.prank(alice); vm.expectRevert(); NativeBridge(address(nativeBridge)).claimRefund(alice);
        _assertSolvent();
    }

    function test_DepositTransferHookCannotReenter() public {
        DepositReentry hook = new DepositReentry();
        hook.configure(address(nativeBridge), abi.encodeWithSignature("lock(uint256,address,uint256)", CHAIN_B, alice, 1 ether));
        vm.prank(alice); token.registerTransferHook(address(hook));
        Message memory message = _deposit(alice, 100 ether, 0, "");
        assertFalse(hook.succeeded());
        assertEq(message.nonce, 0);
        _assertSolvent();
    }

    function test_HostileHookFailuresDoNotRevertMintOrConsumeOtherFunds() public {
        HostileHook hook = new HostileHook();
        for (uint256 i; i < 3; ++i) {
            Message memory message = _deposit(address(hook), 10 ether, 200_000, "");
            vm.chainId(CHAIN_B);
            bytes[] memory signatures = _sign(message, wrappedBridge);
            hook.configure(HostileHook.Mode(i), address(wrappedBridge), message, signatures);
            uint256 beforeBalance = wrappedToken.balanceOf(address(hook));
            wrappedBridge.mint(message, signatures);
            assertEq(wrappedToken.balanceOf(address(hook)) - beforeBalance, message.amount / 1e12);
            assertTrue(WrappedBridge(address(wrappedBridge)).failedHooks(keccak256(abi.encode(message))));
        }
    }

    function test_HookCannotReenterMint() public {
        HostileHook hook = new HostileHook();
        Message memory message = _deposit(address(hook), 10 ether, 500_000, "");
        vm.chainId(CHAIN_B);
        bytes[] memory signatures = _sign(message, wrappedBridge);
        hook.configure(HostileHook.Mode.Reenter, address(wrappedBridge), message, signatures);
        wrappedBridge.mint(message, signatures);
        assertFalse(hook.reentrySucceeded());
        assertEq(wrappedToken.balanceOf(address(hook)), message.amount / 1e12);
    }

    function test_UnderfundedRelayerCannotManufactureHookFailure() public {
        HostileHook hook = new HostileHook();
        Message memory message = _deposit(address(hook), 10 ether, 500_000, "");
        vm.chainId(CHAIN_B);
        bytes[] memory signatures = _sign(message, wrappedBridge);
        (bool ok,) = address(wrappedBridge).call{gas: 400_000}(abi.encodeCall(IWrappedBridge.mint, (message, signatures)));
        assertFalse(ok);
        assertEq(wrappedToken.balanceOf(address(hook)), 0);
        assertFalse(WrappedBridge(address(wrappedBridge)).processed(message.nonce));
        wrappedBridge.mint(message, signatures);
        assertEq(wrappedToken.balanceOf(address(hook)), message.amount / 1e12);
    }
}
