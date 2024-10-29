// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TOK.sol";
import "./Authorizable.sol";

// MasterGardener is the master gardener of whatever gardens are available.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TOK is sufficiently
// distributed and the community can show to govern itself.
//
contract MasterGardener is Ownable, Authorizable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardDebtAtTimestamp; // the last timestamp user stake
        uint256 lastWithdrawTimestamp; // the last timestamp a user withdrew at.
        uint256 firstDepositTimestamp; // the last timestamp a user deposited at.
        uint256 timestampdelta; // time passed since withdrawals
        uint256 lastDepositTimestamp;
        //
        // We do some fancy math here. Basically, at any point in time, the
        // amount of TOK
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGovTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGovTokenPerShare` (and `lastRewardTimestamp`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. TOK to distribute per second.
        uint256 lastRewardTimestamp; // Last timestamp that TOK distribution occurs.
        uint256 accGovTokenPerShare; // Accumulated TOK per share, times 1e12. See below.
    }

    // The TOK token
    TOK public govToken;
    // Dev address.
    address public devaddr;
    // TOK created per second.
    uint256 public REWARD_PER_SEC;
    // Bonus multiplier for early TOK makers.
    uint256[] public REWARD_MULTIPLIER; // init in constructor function
    uint256[] public HALVING_AT_TIMESTAMP; // init in constructor function
    uint256[] public timestampDeltaStartStage;
    uint256[] public timestampDeltaEndStage;
    uint256[] public userFeeStage;
    uint256[] public devFeeStage;
    uint256 public FINISH_BONUS_AT_TIMESTAMP;
    uint256 public userDepFee;
    uint256 public devDepFee;

    // The timestamp when TOK mining starts.
    uint256 public START_TIMESTAMP;

    uint256[] public PERCENT_LOCK_BONUS_REWARD; // lock xx% of bounus reward
    uint256 public PERCENT_FOR_DEV; // dev bounties

    // Info of each pool.
    PoolInfo[] public poolInfo;
    mapping(address => uint256) public poolId1; // poolId1 starting from 1, subtract 1 before using with poolInfo
    // Info of each user that stakes LP tokens. pid => user address => info
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(IERC20 => bool) public poolExistence;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SendGovernanceTokenReward(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 lockAmount
    );

    modifier nonDuplicated(IERC20 _lpToken) {
        require(
            poolExistence[_lpToken] == false,
            "MasterGardener::nonDuplicated: duplicated"
        );
        _;
    }

    constructor(
        TOK _govToken,
        uint256 _rewardPerSec,
        uint256 _startTimestamp,
        uint256 _halvingAfterTimestamp,
        uint256 _userDepFee,
        uint256[] memory _rewardMultiplier,
        uint256[] memory _timestampDeltaStartStage,
        uint256[] memory _timestampDeltaEndStage,
        uint256[] memory _userFeeStage,
        uint256[] memory _devFeeStage,
        uint256[] memory _lockPercent
    ) public {
        govToken = _govToken;
        REWARD_PER_SEC = _rewardPerSec;
        START_TIMESTAMP = _startTimestamp;
        userDepFee = _userDepFee;

        REWARD_MULTIPLIER = _rewardMultiplier;
        timestampDeltaStartStage = _timestampDeltaStartStage;
        timestampDeltaEndStage = _timestampDeltaEndStage;
        userFeeStage = _userFeeStage;
        devFeeStage = _devFeeStage;
        PERCENT_LOCK_BONUS_REWARD = _lockPercent;
        PERCENT_FOR_DEV = 20;

        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtTimestamp = _halvingAfterTimestamp
                .mul(i + 1)
                .add(_startTimestamp)
                .add(1);
            HALVING_AT_TIMESTAMP.push(halvingAtTimestamp);
        }

        FINISH_BONUS_AT_TIMESTAMP = _halvingAfterTimestamp
            .mul(REWARD_MULTIPLIER.length - 1)
            .add(_startTimestamp);
        HALVING_AT_TIMESTAMP.push(uint256(-1));
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_lpToken) {
        require(
            poolId1[address(_lpToken)] == 0,
            "MasterGardener::add: lp is already in pool"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTimestamp = block.timestamp > START_TIMESTAMP
            ? block.timestamp
            : START_TIMESTAMP;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolId1[address(_lpToken)] = poolInfo.length + 1;
        poolExistence[_lpToken] = true;
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardTimestamp: lastRewardTimestamp,
                accGovTokenPerShare: 0
            })
        );
    }

    // Update the given pool's TOK allocation points. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 GovTokenForDev;
        uint256 GovTokenForFarmer;
        (GovTokenForDev, GovTokenForFarmer) = getPoolReward(
            pool.lastRewardTimestamp,
            block.timestamp,
            pool.allocPoint
        );
        // Mint some new TOK tokens for the farmer and store them in MasterGardener.
        govToken.mint(address(this), GovTokenForFarmer);
        pool.accGovTokenPerShare = pool.accGovTokenPerShare.add(
            GovTokenForFarmer.mul(1e12).div(lpSupply)
        );
        pool.lastRewardTimestamp = block.timestamp;
        if (GovTokenForDev > 0) {
            govToken.mint(address(devaddr), GovTokenForDev);
            // Dev fund has xx% locked during the starting bonus period. After which locked funds drip out linearly each block over 1x years.
            if (block.timestamp <= FINISH_BONUS_AT_TIMESTAMP) {
                govToken.lock(
                    address(devaddr),
                    GovTokenForDev.mul(100).div(100)
                );
            }
        }
    }

    // |--------------------------------------|
    // [20, 30, 40, 50, 60, 70, 80, 99999999]
    // Return reward multiplier over the given _from to _to timestamp.
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_TIMESTAMP) return 0;

        for (uint256 i = 0; i < HALVING_AT_TIMESTAMP.length; i++) {
            uint256 endTimestamp = HALVING_AT_TIMESTAMP[i];
            if (i > REWARD_MULTIPLIER.length - 1) return 0;

            if (_to <= endTimestamp) {
                uint256 m = _to.sub(_from).mul(REWARD_MULTIPLIER[i]);
                return result.add(m);
            }

            if (_from < endTimestamp) {
                uint256 m = endTimestamp.sub(_from).mul(REWARD_MULTIPLIER[i]);
                _from = endTimestamp;
                result = result.add(m);
            }
        }

        return result;
    }

    function getLockPercentage(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256) {
        uint256 result = 0;
        if (_from < START_TIMESTAMP) return 100;

        for (uint256 i = 0; i < HALVING_AT_TIMESTAMP.length; i++) {
            uint256 endTimestamp = HALVING_AT_TIMESTAMP[i];
            if (i > PERCENT_LOCK_BONUS_REWARD.length - 1) return 0;

            if (_to <= endTimestamp) {
                return PERCENT_LOCK_BONUS_REWARD[i];
            }
        }

        return result;
    }

    function getPoolReward(
        uint256 _from,
        uint256 _to,
        uint256 _allocPoint
    ) public view returns (uint256 forDev, uint256 forFarmer) {
        uint256 multiplier = getMultiplier(_from, _to);
        uint256 amount = multiplier.mul(REWARD_PER_SEC).mul(_allocPoint).div(
            totalAllocPoint
        );
        uint256 GovernanceTokenCanMint = govToken.cap().sub(
            govToken.totalSupply()
        );

        if (GovernanceTokenCanMint < amount) {
            // If there aren't enough governance tokens left to mint before the cap,
            // just give all of the possible tokens left to the farmer.
            forDev = 0;
            forFarmer = GovernanceTokenCanMint;
        } else {
            // Otherwise, give the farmer their full amount and also give some
            // extra to the dev, LP, com, and founders wallets.
            forDev = amount.mul(PERCENT_FOR_DEV).div(100);
            forFarmer = amount;
        }
    }

    // View function to see pending TOK on frontend.
    function pendingReward(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGovTokenPerShare = pool.accGovTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply > 0) {
            uint256 GovTokenForFarmer;
            (, GovTokenForFarmer) = getPoolReward(
                pool.lastRewardTimestamp,
                block.timestamp,
                pool.allocPoint
            );
            accGovTokenPerShare = accGovTokenPerShare.add(
                GovTokenForFarmer.mul(1e12).div(lpSupply)
            );
        }
        return
            user.amount.mul(accGovTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    function claimRewards(uint256[] memory _pids) public {
        for (uint256 i = 0; i < _pids.length; i++) {
            claimReward(_pids[i]);
        }
    }

    function claimReward(uint256 _pid) public {
        updatePool(_pid);
        _harvest(_pid);
    }

    // lock a % of reward if it comes from bonus time.
    function _harvest(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        // Only harvest if the user amount is greater than 0.
        if (user.amount > 0) {
            // Calculate the pending reward. This is the user's amount of LP
            // tokens multiplied by the accGovTokenPerShare of the pool, minus
            // the user's rewardDebt.
            uint256 pending = user
                .amount
                .mul(pool.accGovTokenPerShare)
                .div(1e12)
                .sub(user.rewardDebt);

            // Make sure we aren't giving more tokens than we have in the
            // MasterGardener contract.
            uint256 masterBal = govToken.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }

            if (pending > 0) {
                // If the user has a positive pending balance of tokens, transfer
                // those tokens from MasterGardener to their wallet.
                govToken.transfer(msg.sender, pending);
                uint256 lockAmount = 0;
                if (user.rewardDebtAtTimestamp <= FINISH_BONUS_AT_TIMESTAMP) {
                    // If we are before the FINISH_BONUS_AT_TIMESTAMP number, we need
                    // to lock some of those tokens, based on the current lock
                    // percentage of their tokens they just received.
                    uint256 lockPercentage = getLockPercentage(
                        block.timestamp - 1,
                        block.timestamp
                    );
                    lockAmount = pending.mul(lockPercentage).div(100);
                    govToken.lock(msg.sender, lockAmount);
                }

                // Reset the rewardDebtAtTimestamp to the current block for the user.
                user.rewardDebtAtTimestamp = block.timestamp;

                emit SendGovernanceTokenReward(
                    msg.sender,
                    _pid,
                    pending,
                    lockAmount
                );
            }

            // Recalculate the rewardDebt for the user.
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(
                1e12
            );
        }
    }

    // Deposit LP tokens to MasterGardener for TOK allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _ref
    ) public nonReentrant {
        require(
            _amount > 0,
            "MasterGardener::deposit: amount must be greater than 0"
        );

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        UserInfo storage devr = userInfo[_pid][devaddr];

        // When a user deposits, we need to update the pool and harvest beforehand,
        // since the rates will change.
        updatePool(_pid);
        _harvest(_pid);
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        if (user.amount == 0) {
            user.rewardDebtAtTimestamp = block.timestamp;
        }
        user.amount = user.amount.add(
            _amount.sub(_amount.mul(userDepFee).div(10000))
        );
        user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(1e12);
        devr.amount = devr.amount.add(_amount.mul(userDepFee).div(10000));
        devr.rewardDebt = devr.amount.mul(pool.accGovTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
        if (user.firstDepositTimestamp > 0) {} else {
            user.firstDepositTimestamp = block.timestamp;
        }
        user.lastDepositTimestamp = block.timestamp;
    }

    // Withdraw LP tokens from MasterGardener.
    function withdraw(
        uint256 _pid,
        uint256 _amount,
        address _ref
    ) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "MasterGardener::withdraw: not good");

        updatePool(_pid);
        _harvest(_pid);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if (user.lastWithdrawTimestamp > 0) {
                user.timestampdelta =
                    block.timestamp -
                    user.lastWithdrawTimestamp;
            } else {
                user.timestampdelta =
                    block.timestamp -
                    user.firstDepositTimestamp;
            }

            if (
                user.timestampdelta < timestampDeltaStartStage[0] ||
                block.timestamp == user.lastDepositTimestamp
            ) {
                //25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[0]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[0]).div(100)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[1] &&
                user.timestampdelta <= timestampDeltaEndStage[0]
            ) {
                //8% fee if a user deposits and withdraws in between same block and 59 minutes.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[1]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[1]).div(100)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[2] &&
                user.timestampdelta <= timestampDeltaEndStage[1]
            ) {
                //4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[2]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[2]).div(100)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[3] &&
                user.timestampdelta <= timestampDeltaEndStage[2]
            ) {
                //2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[3]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[3]).div(100)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[4] &&
                user.timestampdelta <= timestampDeltaEndStage[3]
            ) {
                //1% fee if a user deposits and withdraws after 3 days but before 5 days.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[4]).div(100)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[4]).div(100)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[5] &&
                user.timestampdelta <= timestampDeltaEndStage[4]
            ) {
                //0.5% fee if a user deposits and withdraws if the user withdraws after 5 days but before 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[5]).div(1000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[5]).div(1000)
                );
            } else if (
                user.timestampdelta >= timestampDeltaStartStage[6] &&
                user.timestampdelta <= timestampDeltaEndStage[5]
            ) {
                //0.25% fee if a user deposits and withdraws after 2 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[6]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[6]).div(10000)
                );
            } else if (user.timestampdelta > timestampDeltaStartStage[7]) {
                //0.1% fee if a user deposits and withdraws after 4 weeks.
                pool.lpToken.safeTransfer(
                    address(msg.sender),
                    _amount.mul(userFeeStage[7]).div(10000)
                );
                pool.lpToken.safeTransfer(
                    address(devaddr),
                    _amount.mul(devFeeStage[7]).div(10000)
                );
            }
            user.rewardDebt = user.amount.mul(pool.accGovTokenPerShare).div(
                1e12
            );
            emit Withdraw(msg.sender, _pid, _amount);
            user.lastWithdrawTimestamp = block.timestamp;
        }
    }

    function withdrawFeePercent(uint256 _pid) public view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 timestampdelta;
        if (user.lastWithdrawTimestamp > 0) {
            timestampdelta = block.timestamp - user.lastWithdrawTimestamp;
        } else {
            timestampdelta = block.timestamp - user.firstDepositTimestamp;
        }

        if (
            timestampdelta < timestampDeltaStartStage[0] ||
            block.timestamp == user.lastDepositTimestamp
        ) {
            return 0;
        } else if (
            timestampdelta >= timestampDeltaStartStage[1] &&
            timestampdelta <= timestampDeltaEndStage[0]
        ) {
            return 1;
        } else if (
            timestampdelta >= timestampDeltaStartStage[2] &&
            timestampdelta <= timestampDeltaEndStage[1]
        ) {
            return 2;
        } else if (
            timestampdelta >= timestampDeltaStartStage[3] &&
            timestampdelta <= timestampDeltaEndStage[2]
        ) {
            return 3;
        } else if (
            timestampdelta >= timestampDeltaStartStage[4] &&
            timestampdelta <= timestampDeltaEndStage[3]
        ) {
            return 4;
        } else if (
            timestampdelta >= timestampDeltaStartStage[5] &&
            timestampdelta <= timestampDeltaEndStage[4]
        ) {
            return 5;
        } else if (
            timestampdelta >= timestampDeltaStartStage[6] &&
            timestampdelta <= timestampDeltaEndStage[5]
        ) {
            return 6;
        } else if (timestampdelta > timestampDeltaStartStage[7]) {
            return 7;
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY. This has the same 25% fee as same block withdrawals to prevent abuse of thisfunction.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = user.amount.mul(75).div(100);
        uint256 devToSend = user.amount.mul(25).div(100);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amountToSend);
        pool.lpToken.safeTransfer(address(devaddr), devToSend);
        emit EmergencyWithdraw(msg.sender, _pid, amountToSend);
    }

    // Safe GovToken transfer function, just in case if rounding error causes pool to not have enough GovTokens.
    function safeGovTokenTransfer(address _to, uint256 _amount) internal {
        uint256 govTokenBal = govToken.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > govTokenBal) {
            transferSuccess = govToken.transfer(_to, govTokenBal);
        } else {
            transferSuccess = govToken.transfer(_to, _amount);
        }
        require(
            transferSuccess,
            "MasterGardener::safeGovTokenTransfer: transfer failed"
        );
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public onlyAuthorized {
        devaddr = _devaddr;
    }

    // Update Finish Bonus Second
    function bonusFinishUpdate(uint256 _newFinish) public onlyAuthorized {
        FINISH_BONUS_AT_TIMESTAMP = _newFinish;
    }

    // Update Halving At Second
    function halvingUpdate(uint256[] memory _newHalving) public onlyAuthorized {
        HALVING_AT_TIMESTAMP = _newHalving;
    }

    // Update Reward Per Second
    function rewardUpdate(uint256 _newReward) public onlyAuthorized {
        REWARD_PER_SEC = _newReward;
    }

    // Update Rewards Mulitplier Array
    function rewardMulUpdate(
        uint256[] memory _newMulReward
    ) public onlyAuthorized {
        REWARD_MULTIPLIER = _newMulReward;
    }

    // Update % lock for general users
    function lockUpdate(uint256[] memory _newlock) public onlyAuthorized {
        PERCENT_LOCK_BONUS_REWARD = _newlock;
    }

    // Update % lock for dev
    function lockdevUpdate(uint256 _newdevlock) public onlyAuthorized {
        PERCENT_FOR_DEV = _newdevlock;
    }

    // Update START_TIMESTAMP
    function starblockUpdate(uint256 _newstarblock) public onlyAuthorized {
        START_TIMESTAMP = _newstarblock;
    }

    function getNewRewardPerBlock(uint256 pid1) public view returns (uint256) {
        uint256 multiplier = getMultiplier(
            block.timestamp - 1,
            block.timestamp
        );
        if (pid1 == 0) {
            return multiplier.mul(REWARD_PER_SEC);
        } else {
            return
                multiplier
                    .mul(REWARD_PER_SEC)
                    .mul(poolInfo[pid1 - 1].allocPoint)
                    .div(totalAllocPoint);
        }
    }

    function userDelta(uint256 _pid) public view returns (uint256) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.lastWithdrawTimestamp > 0) {
            uint256 estDelta = block.timestamp - user.lastWithdrawTimestamp;
            return estDelta;
        } else {
            uint256 estDelta = block.timestamp - user.firstDepositTimestamp;
            return estDelta;
        }
    }

    function reviseWithdraw(
        uint256 _pid,
        address _user,
        uint256 timestamp
    ) public onlyAuthorized {
        UserInfo storage user = userInfo[_pid][_user];
        user.lastWithdrawTimestamp = timestamp;
    }

    function reviseDeposit(
        uint256 _pid,
        address _user,
        uint256 timestamp
    ) public onlyAuthorized {
        UserInfo storage user = userInfo[_pid][_user];
        user.firstDepositTimestamp = timestamp;
    }

    function setStageStarts(
        uint256[] memory _timestampStarts
    ) public onlyAuthorized {
        timestampDeltaStartStage = _timestampStarts;
    }

    function setStageEnds(
        uint256[] memory _timestampEnds
    ) public onlyAuthorized {
        timestampDeltaEndStage = _timestampEnds;
    }

    function setUserFeeStage(uint256[] memory _userFees) public onlyAuthorized {
        userFeeStage = _userFees;
    }

    function setDevFeeStage(uint256[] memory _devFees) public onlyAuthorized {
        devFeeStage = _devFees;
    }

    function setDevDepFee(uint256 _devDepFees) public onlyAuthorized {
        devDepFee = _devDepFees;
    }

    function setUserDepFee(uint256 _usrDepFees) public onlyAuthorized {
        userDepFee = _usrDepFees;
    }

    function reclaimTokenOwnership(address _newOwner) public onlyAuthorized {
        govToken.transferOwnership(_newOwner);
    }
}
