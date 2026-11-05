// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BridgeTestFixture} from "./BridgeTestFixture.sol";
import {Message} from "../src/interfaces/IHarborBridge.sol";
import {StakeOnArrival} from "../src/StakeOnArrival.sol";
import {WrappedBridge} from "../src/WrappedBridge.sol";
import {HarborStaking} from "../src/staking/HarborStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BeneficiaryWallet {
    function sendToken(IERC20 token, address to, uint256 amount) external { token.transfer(to, amount); }
}

contract StakingSecurityTest is BridgeTestFixture {
    HarborStaking private staking;
    StakeOnArrival private receiver;

    function setUp() public override {
        super.setUp();
        vm.chainId(CHAIN_B);
        staking = new HarborStaking(address(wrappedToken), 1e6, block.timestamp, block.timestamp + 30 days, admin);
        receiver = new StakeOnArrival(address(wrappedBridge), address(wrappedToken), address(staking), 0);
        vm.startPrank(admin);
        staking.add(100, address(wrappedToken));
        staking.setOperator(address(receiver), true);
        vm.stopPrank();
    }

    function _send(address target, bytes memory data, uint256 gasLimit) private returns (Message memory message) {
        vm.chainId(CHAIN_A);
        vm.startPrank(alice);
        token.approve(address(nativeBridge), 10 ether);
        vm.recordLogs();
        nativeBridge.lockWithHook(CHAIN_B, target, 10 ether, gasLimit, data);
        vm.stopPrank();
        (, message) = _lastMessageSent();
        vm.chainId(CHAIN_B);
        wrappedBridge.mint(message, _sign(message, wrappedBridge));
    }

    function _arrival() private returns (Message memory) { return _send(address(receiver), abi.encode(alice), 500_000); }

    function _assertEmpty() private view {
        assertEq(wrappedToken.balanceOf(address(receiver)), 0);
        assertEq(wrappedToken.allowance(address(receiver), address(staking)), 0);
        assertEq(staking.stakedAmount(0, address(receiver)), 0);
    }

    function test_StakedPrincipalWithdrawableByBeneficiary() public {
        Message memory message = _arrival();
        assertEq(staking.stakedAmount(0, alice), message.amount / 1e12);
        _assertEmpty();
        vm.warp(staking.unlockTime(0, alice));
        vm.prank(alice); staking.withdraw(0, message.amount / 1e12, alice);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
    }

    function test_RevokedOperatorFallsBackToLiquidTokens() public {
        vm.prank(admin); staking.setOperator(address(receiver), false);
        Message memory message = _arrival();
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        assertEq(staking.stakedAmount(0, alice), 0);
        _assertEmpty();
    }

    function test_MissingPoolFallsBack() public {
        StakeOnArrival missing = new StakeOnArrival(address(wrappedBridge), address(wrappedToken), address(staking), 99);
        vm.prank(admin); staking.setOperator(address(missing), true);
        Message memory message = _send(address(missing), abi.encode(alice), 500_000);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        assertEq(wrappedToken.balanceOf(address(missing)), 0);
    }

    function test_WrongPoolTokenFallsBack() public {
        vm.prank(admin); staking.add(100, address(token));
        StakeOnArrival wrong = new StakeOnArrival(address(wrappedBridge), address(wrappedToken), address(staking), 1);
        vm.prank(admin); staking.setOperator(address(wrong), true);
        Message memory message = _send(address(wrong), abi.encode(alice), 500_000);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        assertEq(staking.stakedAmount(1, alice), 0);
    }

    function test_PartialDepositReturnsRemainder() public {
        vm.prank(admin); staking.setDepositCap(0, 3e6);
        Message memory message = _arrival();
        assertEq(staking.stakedAmount(0, alice), 3e6);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12 - 3e6);
        _assertEmpty();
    }

    function test_FullPoolReturnsAllTokens() public {
        vm.prank(admin); staking.setDepositCap(0, 3e6);
        // Populate the pool with a different account so the cap check, not existing-stake protection, fails.
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(address(this), 3e6);
        wrappedToken.approve(address(staking), 3e6);
        staking.deposit(0, 3e6, address(this));
        Message memory message = _arrival();
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        assertEq(staking.stakedAmount(0, alice), 0);
        _assertEmpty();
    }

    function test_ContractBeneficiaryReceivesSpendableTokens() public {
        BeneficiaryWallet wallet = new BeneficiaryWallet();
        Message memory message = _send(address(receiver), abi.encode(address(wallet)), 500_000);
        assertEq(staking.stakedAmount(0, address(wallet)), 0);
        assertEq(wrappedToken.balanceOf(address(wallet)), message.amount / 1e12);
        wallet.sendToken(IERC20(address(wrappedToken)), alice, message.amount / 1e12);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
        _assertEmpty();
    }

    function test_ThirdPartyCannotForceStakeOrLock() public {
        address bob = makeAddr("bob");
        Message memory message = _send(address(receiver), abi.encode(bob), 500_000);
        assertEq(wrappedToken.balanceOf(bob), message.amount / 1e12);
        assertEq(staking.stakedAmount(0, bob), 0);
        assertEq(staking.unlockTime(0, bob), 0);
        _assertEmpty();
    }

    function test_DelayedSelfArrivalCannotExtendExistingWithdrawalLock() public {
        Message memory first = _arrival();
        uint256 originalUnlock = staking.unlockTime(0, alice);
        vm.warp(block.timestamp + 6 days);
        Message memory second = _arrival();
        assertEq(staking.unlockTime(0, alice), originalUnlock);
        assertEq(staking.stakedAmount(0, alice), first.amount / 1e12);
        assertEq(wrappedToken.balanceOf(alice), second.amount / 1e12);
        vm.warp(originalUnlock);
        vm.prank(alice); staking.emergencyWithdraw(0, alice);
        assertEq(wrappedToken.balanceOf(alice), (first.amount + second.amount) / 1e12);
        _assertEmpty();
    }

    function test_ZeroAddressMalformedAndUnsafeBeneficiariesRecoverToSender() public {
        bytes[] memory inputs = new bytes[](5);
        inputs[0] = abi.encode(address(0));
        inputs[1] = hex"1234";
        inputs[2] = abi.encode(type(uint256).max);
        inputs[3] = abi.encode(address(receiver));
        inputs[4] = "";
        // Disable staking so each fallback is visible as liquid balance.
        vm.prank(admin); staking.setOperator(address(receiver), false);
        uint256 total;
        for (uint256 i; i < inputs.length; ++i) {
            Message memory message = _send(address(receiver), inputs[i], 500_000);
            total += message.amount / 1e12;
        }
        assertEq(wrappedToken.balanceOf(alice), total);
        _assertEmpty();
    }

    function test_UnauthorizedCallbacksAndStakeAttemptsRevert() public {
        vm.expectRevert(); receiver.onBridgeReceived(CHAIN_A, alice, 100, abi.encode(alice));
        vm.expectRevert(); receiver.attemptStake(alice, 100);
        Message memory fake = Message(CHAIN_A, CHAIN_B, 0, alice, address(receiver), 1e12, 100, abi.encode(alice));
        vm.expectRevert(); receiver.recoverFailed(fake);
    }

    function test_OutOfGasHookRecoverableExactlyOnceByAnyone() public {
        Message memory message = _send(address(receiver), abi.encode(alice), 1000);
        uint256 amount = message.amount / 1e12;
        assertEq(wrappedToken.balanceOf(address(receiver)), amount);
        assertTrue(WrappedBridge(address(wrappedBridge)).failedHooks(keccak256(abi.encode(message))));
        receiver.recoverFailed(message);
        assertEq(wrappedToken.balanceOf(alice), amount);
        assertEq(wrappedToken.balanceOf(address(this)), 0);
        vm.expectRevert(); receiver.recoverFailed(message);
        _assertEmpty();
    }

    function test_RetryWithMoreGasDoesNotMintTwice() public {
        Message memory message = _send(address(receiver), abi.encode(alice), 1000);
        uint256 supply = wrappedToken.totalSupply();
        WrappedBridge(address(wrappedBridge)).retryHook(message, 500_000);
        assertEq(wrappedToken.totalSupply(), supply);
        assertEq(staking.stakedAmount(0, alice), message.amount / 1e12);
        vm.expectRevert(); receiver.recoverFailed(message);
        vm.expectRevert(); WrappedBridge(address(wrappedBridge)).retryHook(message, 500_000);
        _assertEmpty();
    }

    function test_FailedRetryPreservesRecovery() public {
        Message memory message = _send(address(receiver), abi.encode(alice), 1000);
        WrappedBridge(address(wrappedBridge)).retryHook(message, 1000);
        receiver.recoverFailed(message);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
    }

    function test_RecoverySurvivesPauseAndValidatorRotation() public {
        Message memory message = _send(address(receiver), abi.encode(alice), 1000);
        vm.startPrank(admin);
        wrappedBridge.setValidators(validatorAddresses, THRESHOLD);
        WrappedBridge(address(wrappedBridge)).setPaused(true);
        vm.stopPrank();
        receiver.recoverFailed(message);
        assertEq(wrappedToken.balanceOf(alice), message.amount / 1e12);
    }

    function test_RecoveryCannotSubstituteBeneficiaryAmountOrNonce() public {
        Message memory message = _send(address(receiver), abi.encode(alice), 1000);
        message.hookData = abi.encode(address(this));
        vm.expectRevert(); receiver.recoverFailed(message);
        message.hookData = abi.encode(alice);
        ++message.nonce;
        vm.expectRevert(); receiver.recoverFailed(message);
        --message.nonce;
        message.amount += 1e12;
        vm.expectRevert(); receiver.recoverFailed(message);
        message.amount -= 1e12;
        vm.expectRevert(); WrappedBridge(address(wrappedBridge)).consumeFailedHook(message);
        receiver.recoverFailed(message);
        assertEq(wrappedToken.balanceOf(address(this)), 0);
    }

    function test_FailedMessagesAndDonationsStayIsolated() public {
        address bob = makeAddr("bob");
        Message memory first = _send(address(receiver), abi.encode(alice), 1000);
        Message memory second = _send(address(receiver), abi.encode(bob), 1000);
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(address(receiver), 777);
        Message memory success = _arrival();
        assertEq(staking.stakedAmount(0, alice), success.amount / 1e12);
        assertEq(wrappedToken.balanceOf(address(receiver)), (first.amount + second.amount) / 1e12 + 777);
        receiver.recoverFailed(second);
        receiver.recoverFailed(first);
        assertEq(wrappedToken.balanceOf(alice), first.amount / 1e12);
        assertEq(wrappedToken.balanceOf(bob), second.amount / 1e12);
        assertEq(wrappedToken.balanceOf(address(receiver)), 777);
    }

    function test_DepositRewardsAreForwardedToTheirOwner() public {
        // A prior position was withdrawn without harvesting. A new deposit settles its
        // pending reward to the operator; the adapter must forward it to Alice.
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(alice, 10e6);
        vm.startPrank(alice);
        wrappedToken.approve(address(staking), 10e6);
        staking.deposit(0, 10e6, alice);
        vm.stopPrank();
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(address(this), 1_000_000e6);
        wrappedToken.approve(address(staking), 1_000_000e6);
        staking.fundRewards(1_000_000e6);
        vm.warp(staking.unlockTime(0, alice));
        vm.prank(alice); staking.withdraw(0, 10e6, alice);
        uint256 pending = staking.pendingReward(0, alice);
        assertGt(pending, 0);
        uint256 balanceBefore = wrappedToken.balanceOf(alice);
        Message memory message = _arrival();
        assertEq(staking.stakedAmount(0, alice), message.amount / 1e12);
        assertEq(wrappedToken.balanceOf(alice) - balanceBefore, pending);
        assertEq(staking.pendingReward(0, alice), 0);
        _assertEmpty();
    }

    function test_PartialDepositAndRewardsAccountedSeparately() public {
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(alice, 10e6);
        vm.startPrank(alice);
        wrappedToken.approve(address(staking), 10e6);
        staking.deposit(0, 10e6, alice);
        vm.stopPrank();
        vm.prank(address(wrappedBridge)); wrappedToken.bridgeMint(address(this), 1_000_000e6);
        wrappedToken.approve(address(staking), 1_000_000e6);
        staking.fundRewards(1_000_000e6);
        vm.warp(staking.unlockTime(0, alice));
        vm.prank(alice); staking.withdraw(0, 10e6, alice);
        vm.prank(admin); staking.setDepositCap(0, 3e6);
        uint256 pending = staking.pendingReward(0, alice);
        uint256 balanceBefore = wrappedToken.balanceOf(alice);
        Message memory message = _arrival();
        assertEq(staking.stakedAmount(0, alice), 3e6);
        assertEq(wrappedToken.balanceOf(alice) - balanceBefore, pending + message.amount / 1e12 - 3e6);
        _assertEmpty();
    }
}
