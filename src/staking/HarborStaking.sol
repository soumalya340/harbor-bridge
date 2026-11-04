// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHarborStaking} from "../interfaces/IHarborStaking.sol";

/// @title HarborStaking
/// @notice Deployed on Chain B and operated by the Harbor staking team. Final — do not modify.
contract HarborStaking is IHarborStaking, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    struct PoolInfo {
        IERC20 stakingToken;
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accRewardPerShare;
        uint256 totalStaked;
        uint256 depositCap;
    }

    uint256 private constant ACC_PRECISION = 1e18;
    uint256 public constant LOCK_DURATION = 7 days;

    IERC20 public immutable rewardToken;
    address public admin;
    uint256 public rewardPerSecond;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public totalAllocPoint;
    uint256 public rewardReserve;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => uint256)) public unpaidRewards;
    mapping(uint256 => mapping(address => uint256)) public unlockTime;
    mapping(address => bool) public isOperator;

    event Deposit(address indexed caller, uint256 indexed pid, uint256 amount, address indexed account);
    event Withdraw(address indexed caller, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed caller, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed caller, uint256 indexed pid, uint256 amount, address indexed to);
    event RewardsFunded(address indexed funder, uint256 amount);
    event OperatorSet(address indexed operator, bool allowed);
    event DepositCapSet(uint256 indexed pid, uint256 cap);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(
        address rewardTokenAddress,
        uint256 initialRewardPerSecond,
        uint256 initialStartTime,
        uint256 initialEndTime,
        address adminAddress
    ) {
        require(rewardTokenAddress != address(0) && adminAddress != address(0), "zero address");
        require(initialEndTime >= initialStartTime, "bad period");
        rewardToken = IERC20(rewardTokenAddress);
        rewardPerSecond = initialRewardPerSecond;
        startTime = initialStartTime;
        endTime = initialEndTime;
        admin = adminAddress;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // ───────── Admin ─────────

    function add(uint256 allocPoint, address stakingToken) external onlyAdmin {
        require(stakingToken != address(0), "zero token");
        _massUpdatePools();
        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint += allocPoint;
        poolInfo.push(
            PoolInfo({
                stakingToken: IERC20(stakingToken),
                allocPoint: allocPoint,
                lastRewardTime: lastRewardTime,
                accRewardPerShare: 0,
                totalStaked: 0,
                depositCap: 0
            })
        );
    }

    function set(uint256 pid, uint256 allocPoint) external onlyAdmin {
        _massUpdatePools();
        totalAllocPoint = totalAllocPoint - poolInfo[pid].allocPoint + allocPoint;
        poolInfo[pid].allocPoint = allocPoint;
    }

    function setRewardPerSecond(uint256 newRewardPerSecond) external onlyAdmin {
        _massUpdatePools();
        rewardPerSecond = newRewardPerSecond;
    }

    function setEndTime(uint256 newEndTime) external onlyAdmin {
        _massUpdatePools();
        require(newEndTime >= block.timestamp, "end in the past");
        endTime = newEndTime;
    }

    function setDepositCap(uint256 pid, uint256 cap) external onlyAdmin {
        poolInfo[pid].depositCap = cap;
        emit DepositCapSet(pid, cap);
    }

    function setOperator(address operator, bool allowed) external onlyAdmin {
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    // ───────── Rewards ─────────

    function fundRewards(uint256 amount) external nonReentrant {
        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - balanceBefore;
        rewardReserve += received;
        emit RewardsFunded(msg.sender, received);
    }

    function pendingReward(uint256 pid, address user) external view returns (uint256) {
        PoolInfo memory pool = poolInfo[pid];
        UserInfo memory account = userInfo[pid][user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        if (block.timestamp > pool.lastRewardTime && pool.totalStaked > 0 && totalAllocPoint > 0) {
            uint256 reward = _rewardDuration(pool.lastRewardTime, block.timestamp) * rewardPerSecond
                * pool.allocPoint / totalAllocPoint;
            accRewardPerShare += reward * ACC_PRECISION / pool.totalStaked;
        }
        int256 accumulated = int256(account.amount * accRewardPerShare / ACC_PRECISION);
        uint256 earned = accumulated > account.rewardDebt ? uint256(accumulated - account.rewardDebt) : 0;
        return earned + unpaidRewards[pid][user];
    }

    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            if (pool.totalStaked > 0 && totalAllocPoint > 0) {
                uint256 reward = _rewardDuration(pool.lastRewardTime, block.timestamp) * rewardPerSecond
                    * pool.allocPoint / totalAllocPoint;
                pool.accRewardPerShare += reward * ACC_PRECISION / pool.totalStaked;
            }
            pool.lastRewardTime = block.timestamp;
            poolInfo[pid] = pool;
        }
    }

    // ───────── Users ─────────

    function deposit(uint256 pid, uint256 amount, address to) external nonReentrant {
        require(to != address(0) && amount > 0, "invalid deposit");
        require(to == msg.sender || isOperator[msg.sender], "not operator");
        PoolInfo memory pool = updatePool(pid);

        if (pool.depositCap != 0) {
            uint256 room = pool.depositCap > pool.totalStaked ? pool.depositCap - pool.totalStaked : 0;
            require(room > 0, "pool full");
            if (amount > room) amount = room;
        }

        address account = to.code.length == 0 ? to : msg.sender;
        UserInfo storage user = userInfo[pid][account];
        uint256 paid = _settle(pid, account, user, pool.accRewardPerShare);

        uint256 balanceBefore = pool.stakingToken.balanceOf(address(this));
        pool.stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = pool.stakingToken.balanceOf(address(this)) - balanceBefore;

        user.amount += received;
        user.rewardDebt += int256(received * pool.accRewardPerShare / ACC_PRECISION);
        poolInfo[pid].totalStaked += received;
        unlockTime[pid][account] = block.timestamp + LOCK_DURATION;

        if (paid > 0) rewardToken.safeTransfer(msg.sender, paid);
        emit Deposit(msg.sender, pid, received, account);
    }

    function withdraw(uint256 pid, uint256 amount, address to) external nonReentrant {
        require(block.timestamp >= unlockTime[pid][msg.sender], "locked");
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage account = userInfo[pid][msg.sender];
        require(account.amount >= amount, "withdraw: not enough");
        account.rewardDebt -= int256(amount * pool.accRewardPerShare / ACC_PRECISION);
        account.amount -= amount;
        poolInfo[pid].totalStaked -= amount;
        pool.stakingToken.safeTransfer(to, amount);
        emit Withdraw(msg.sender, pid, amount, to);
    }

    function harvest(uint256 pid, address to) external nonReentrant {
        PoolInfo memory pool = updatePool(pid);
        uint256 paid = _settle(pid, msg.sender, userInfo[pid][msg.sender], pool.accRewardPerShare);
        if (paid > 0) rewardToken.safeTransfer(to, paid);
        emit Harvest(msg.sender, pid, paid, to);
    }

    function withdrawAndHarvest(uint256 pid, uint256 amount, address to) external nonReentrant {
        require(block.timestamp >= unlockTime[pid][msg.sender], "locked");
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage account = userInfo[pid][msg.sender];
        require(account.amount >= amount, "withdraw: not enough");

        uint256 paid = _settle(pid, msg.sender, account, pool.accRewardPerShare);
        account.rewardDebt -= int256(amount * pool.accRewardPerShare / ACC_PRECISION);
        account.amount -= amount;
        poolInfo[pid].totalStaked -= amount;

        pool.stakingToken.safeTransfer(to, amount);
        if (paid > 0) rewardToken.safeTransfer(to, paid);
        emit Withdraw(msg.sender, pid, amount, to);
        emit Harvest(msg.sender, pid, paid, to);
    }

    function emergencyWithdraw(uint256 pid, address to) external nonReentrant {
        require(block.timestamp >= unlockTime[pid][msg.sender], "locked");
        UserInfo storage account = userInfo[pid][msg.sender];
        uint256 amount = account.amount;
        account.amount = 0;
        account.rewardDebt = 0;
        unpaidRewards[pid][msg.sender] = 0;
        poolInfo[pid].totalStaked -= amount;
        poolInfo[pid].stakingToken.safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }

    function stakedAmount(uint256 pid, address user) external view returns (uint256) {
        return userInfo[pid][user].amount;
    }

    // ───────── Internal ─────────

    /// @dev Pays out what `account` has earned so far, within the reward reserve. Returns the amount paid.
    function _settle(uint256 pid, address account, UserInfo storage user, uint256 accRewardPerShare)
        internal
        returns (uint256 paid)
    {
        int256 accumulated = int256(user.amount * accRewardPerShare / ACC_PRECISION);
        uint256 owed = (accumulated > user.rewardDebt ? uint256(accumulated - user.rewardDebt) : 0)
            + unpaidRewards[pid][account];
        user.rewardDebt = accumulated;
        paid = owed <= rewardReserve ? owed : rewardReserve;
        unpaidRewards[pid][account] = owed - paid;
        rewardReserve -= paid;
    }

    function _massUpdatePools() internal {
        for (uint256 pid; pid < poolInfo.length; pid++) {
            updatePool(pid);
        }
    }

    function _rewardDuration(uint256 from, uint256 to) internal view returns (uint256) {
        if (to > endTime) to = endTime;
        if (from < startTime) from = startTime;
        return to > from ? to - from : 0;
    }
}
