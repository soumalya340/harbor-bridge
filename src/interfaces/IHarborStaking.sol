// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Fixed interface. Do NOT change anything in this file. See README.
interface IHarborStaking {
    function poolLength() external view returns (uint256);

    function add(uint256 allocPoint, address stakingToken) external;
    function set(uint256 pid, uint256 allocPoint) external;
    function setRewardPerSecond(uint256 rewardPerSecond) external;
    function setEndTime(uint256 endTime) external;
    function setDepositCap(uint256 pid, uint256 cap) external;
    function setOperator(address operator, bool allowed) external;

    function fundRewards(uint256 amount) external;

    function deposit(uint256 pid, uint256 amount, address to) external;
    function withdraw(uint256 pid, uint256 amount, address to) external;
    function harvest(uint256 pid, address to) external;
    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) external;
    function emergencyWithdraw(uint256 pid, address to) external;

    function pendingReward(uint256 pid, address user) external view returns (uint256);
    function stakedAmount(uint256 pid, address user) external view returns (uint256);
    function unlockTime(uint256 pid, address user) external view returns (uint256);
    function isOperator(address operator) external view returns (bool);
}
