// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Notified before tokens leave an account that registered it.
interface ITransferHook {
    function onTokenSend(address from, address to, uint256 amount) external;
}

/// @title HarborToken (HBR)
/// @notice Already deployed on Chain A and owned by the Harbor token team (not the bridge team).
///         - Accounts may register a transfer hook to be notified of outgoing transfers
///           (used by custody partners for their internal bookkeeping).
///         - Every transfer pays a fee to the fee collector, deducted from the amount received.
///           It is 0.3% today. The owner can change it at any time, up to 5%.
contract HarborToken is ERC20, Ownable {
    uint256 public constant MAX_FEE_BPS = 500;

    uint256 public feeBps;
    address public feeCollector;
    mapping(address => address) public transferHookOf;

    event TransferHookRegistered(address indexed account, address hook);
    event FeeUpdated(uint256 feeBps);

    constructor(address initialOwner, address feeCollectorAddress) ERC20("Harbor", "HBR") Ownable(initialOwner) {
        require(feeCollectorAddress != address(0), "zero fee collector");
        feeCollector = feeCollectorAddress;
        feeBps = 30;
        _mint(initialOwner, 1_000_000_000 ether);
    }

    function setFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function registerTransferHook(address hook) external {
        transferHookOf[msg.sender] = hook;
        emit TransferHookRegistered(msg.sender, hook);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            address hook = transferHookOf[from];
            if (hook != address(0)) ITransferHook(hook).onTokenSend(from, to, amount);
        }

        if (feeBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 fee = amount * feeBps / 10_000;
        super._update(from, feeCollector, fee);
        super._update(from, to, amount - fee);
    }
}
