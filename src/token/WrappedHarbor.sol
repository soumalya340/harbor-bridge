// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title WrappedHarbor (wHBR)
/// @notice Chain B representation of HBR. Final — do not modify. Only the bridge can mint and burn.
contract WrappedHarbor is ERC20, Ownable {
    address public bridge;

    constructor(address initialOwner) ERC20("Wrapped Harbor", "wHBR") Ownable(initialOwner) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    modifier onlyBridge() {
        require(msg.sender == bridge, "not bridge");
        _;
    }

    /// @notice The bridge is deployed after the token, so it is set once afterwards.
    function setBridge(address bridgeAddress) external onlyOwner {
        require(bridge == address(0), "bridge already set");
        require(bridgeAddress != address(0), "zero bridge");
        bridge = bridgeAddress;
    }

    function bridgeMint(address recipient, uint256 amount) external onlyBridge {
        _mint(recipient, amount);
    }

    function bridgeBurn(address holder, uint256 amount) external onlyBridge {
        _burn(holder, amount);
    }
}
