// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TKNStakingT2 is Ownable {

    struct Deposit {
        uint256 tokenAmount;
        uint256 weight;
        uint256 lockedUntil;
        uint256 rewardDebt;
    }

    struct UserInfo {
        uint256 tokenAmount;
        uint256 totalWeight;
        uint256 totalRewardsClaimed;
        Deposit[] deposits;
    }

    uint256 public constant ONE_DAY = 10 seconds;
    uint256 public constant MULTIPLIER = 1e18;

    uint256 public lastRewardBlock; // Last block number that TKNs distribution occurs.
    uint256 public accTokenPerUnitWeight; // Accumulated TKNs per weight, times MULTIPLIER.

    // total locked amount across all users
    uint256 public usersLockingAmount;
    // total locked weight across all users
    uint256 public usersLockingWeight;

    // The staking and reward token
    IERC20 public immutable token;
    // TKN tokens rewarded per block.
    uint256 public rewardPerBlock;
    // The accounting of unclaimed TKN rewards
    uint256 public unclaimedTokenRewards;

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    constructor(address _token, uint256 _rewardPerBlock, uint256 _startBlock) {
        require(_startBlock > block.number, "TKNStakingT1: _startBlock must be in the future");
        token = IERC20(_token);
        rewardPerBlock = _rewardPerBlock;
        lastRewardBlock = _startBlock;
    }

    // Returns total staked token balance for the given address
    function balanceOf(address _user) external view returns (uint256) {
        return userInfo[_user].tokenAmount;
    }

    // Returns total staked token weight for the given address
    function weightOf(address _user) external view returns (uint256) {
        return userInfo[_user].totalWeight;
    }

    // Returns information on the given deposit for the given address
    function getDeposit(address _user, uint256 _depositId) external view returns (Deposit memory) {
        return userInfo[_user].deposits[_depositId];
    }

    // Returns number of deposits for the given address. Allows iteration over deposits.
    function getDepositsLength(address _user) external view returns (uint256) {
        return userInfo[_user].deposits.length;
    }

    function getPendingRewardOf(address _staker, uint256 _depositId) external view returns(uint256) {
        UserInfo storage user = userInfo[_staker];
        Deposit storage stakeDeposit = user.deposits[_depositId];

        uint256 _amount = stakeDeposit.tokenAmount;
        uint256 _weight = stakeDeposit.weight;
        uint256 _rewardDebt = stakeDeposit.rewardDebt;

        require(_amount > 0, "TKNStakingT1: Deposit amount is 0");

        // calculate reward upto current block
        uint256 tokenReward = (block.number - lastRewardBlock) * rewardPerBlock;
        uint256 _accTokenPerUnitWeight = accTokenPerUnitWeight + (tokenReward * MULTIPLIER) / usersLockingWeight;
        uint256 _rewardAmount = ((_weight * _accTokenPerUnitWeight) / MULTIPLIER) - _rewardDebt;

        return _rewardAmount;
    }

    function getUnlockSpecs(uint256 _amount, uint256 _lockMode) public view returns(uint256 lockUntil, uint256 weight) {
        require(_lockMode < 4, "TKNStakingT1: Invalid lock mode");

        if(_lockMode == 0) {
            // 0 : 7-day lock
            return (now256() + 7 * ONE_DAY, _amount);
        }
        else if(_lockMode == 1) {
            // 1 : 30-day lock
            return (now256() + 30 * ONE_DAY, _amount + (_amount*10)/100);
        }
        else if(_lockMode == 2) {
            // 2 : 90-day lock
            return (now256() + 90 * ONE_DAY, _amount + (_amount*40)/100);
        }

        // 3 : 180-day lock
        return (now256() + 180 * ONE_DAY, _amount * 2);
    }

    function now256() public view returns (uint256) {
        // return current block timestamp
        return block.timestamp;
    }

    function blockNumber() public view returns (uint256) {
        // return current block number
        return block.number;
    }

    function updateRewardPerBlock(uint256 _newRewardPerBlock) external onlyOwner {
        _sync();
        rewardPerBlock = _newRewardPerBlock;
    }

    // Added to support recovering lost tokens that find their way to this contract
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(token), "TKNStakingT1: Cannot withdraw the staking token");
        IERC20(_tokenAddress).transfer(msg.sender, _tokenAmount);
    }

    // Update reward variables
    function sync() external {
        _sync();
    }

    // Stake tokens
    function stake(uint256 _amount, uint256 _lockMode) external {
        _stake(msg.sender, _amount, _lockMode);
    }

    // Unstake tokens and claim rewards
    function unstake(uint256 _depositId) external {
        _unstake(msg.sender, _depositId, true);
    }

    // Claim rewards
    function claimRewards(uint256 _depositId) external {
        _claimRewards(msg.sender, _depositId);
    }

    // Unstake tokens withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _depositId) external {
        _unstake(msg.sender, _depositId, false);
    }

    function _sync() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }
        uint256 _weightLocked = usersLockingWeight;
        if (_weightLocked == 0) {
            lastRewardBlock = block.number;
            return;
        }
        uint256 tokenReward = (block.number - lastRewardBlock) * rewardPerBlock;

        uint256 surplusToken = token.balanceOf(address(this)) - usersLockingAmount - unclaimedTokenRewards;
        require(surplusToken >= tokenReward, "TKNStakingT1: Insufficient TKN tokens for rewards");
        unclaimedTokenRewards += tokenReward;
        accTokenPerUnitWeight += (tokenReward * MULTIPLIER) / _weightLocked;
        lastRewardBlock = block.number;
    }

    function _stake(address _staker, uint256 _amount, uint256 _lockMode) internal {
        require(_amount > 0, "TKNStakingT1: Deposit amount is 0");
        _sync();

        UserInfo storage user = userInfo[_staker];

        _transferTokenFrom(address(_staker), address(this), _amount);

        (uint256 lockUntil, uint256 stakeWeight) = getUnlockSpecs(_amount, _lockMode);

        // create and save the deposit (append it to deposits array)
        Deposit memory deposit =
            Deposit({
                tokenAmount: _amount,
                weight: stakeWeight,
                lockedUntil: lockUntil,
                rewardDebt: (stakeWeight*accTokenPerUnitWeight) / MULTIPLIER
            });
        // deposit ID is an index of the deposit in `deposits` array
        user.deposits.push(deposit);

        user.tokenAmount += _amount;
        user.totalWeight += stakeWeight;

        // update global variable
        usersLockingWeight += stakeWeight;
        usersLockingAmount += _amount;

        emit Staked(_staker, _amount);
    }

    function _unstake(address _staker, uint256 _depositId, bool _sendRewards) internal {
        UserInfo storage user = userInfo[_staker];
        Deposit storage stakeDeposit = user.deposits[_depositId];

        uint256 _amount = stakeDeposit.tokenAmount;
        uint256 _weight = stakeDeposit.weight;
        uint256 _rewardDebt = stakeDeposit.rewardDebt;

        require(_amount > 0, "TKNStakingT1: Deposit amount is 0");
        require(now256() > stakeDeposit.lockedUntil, "TKNStakingT1: Deposit not unlocked yet");

        if(_sendRewards) {
            _sync();
        }

        uint256 _rewardAmount = ((_weight * accTokenPerUnitWeight) / MULTIPLIER) - _rewardDebt;

        // update user record
        user.tokenAmount -= _amount;
        user.totalWeight = user.totalWeight - _weight;
        user.totalRewardsClaimed += _rewardAmount;

        // update global variable
        usersLockingWeight -= _weight;
        usersLockingAmount -= _amount;
        unclaimedTokenRewards -= _rewardAmount;

        uint256 tokenToSend = _amount;
        if(_sendRewards) {
            // add rewards
            tokenToSend += _rewardAmount;
            emit Claimed(_staker, _rewardAmount);
        }

        delete user.deposits[_depositId];

        // return tokens back to holder
        _safeTokenTransfer(_staker, tokenToSend);
        emit Unstaked(_staker, _amount);
    }

    function _claimRewards(address _staker, uint256 _depositId) internal {
        UserInfo storage user = userInfo[_staker];
        Deposit storage stakeDeposit = user.deposits[_depositId];

        uint256 _amount = stakeDeposit.tokenAmount;
        uint256 _weight = stakeDeposit.weight;
        uint256 _rewardDebt = stakeDeposit.rewardDebt;

        require(_amount > 0, "TKNStakingT1: Deposit amount is 0");
        _sync();

        uint256 _rewardAmount = ((_weight * accTokenPerUnitWeight) / MULTIPLIER) - _rewardDebt;

        // update stakeDeposit record
        stakeDeposit.rewardDebt += _rewardAmount;

        // update user record
        user.totalRewardsClaimed += _rewardAmount;

        // update global variable
        unclaimedTokenRewards -= _rewardAmount;

        // return tokens back to holder
        _safeTokenTransfer(_staker, _rewardAmount);
        emit Claimed(_staker, _rewardAmount);
    }

    function _transferTokenFrom(address _from, address _to, uint256 _value) internal {
        IERC20(token).transferFrom(_from, _to, _value);
    }

    // Safe token transfer function, just in case if rounding error causes contract to not have enough TKN.
    function _safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 tokenBal = token.balanceOf(address(this));
        if (_amount > tokenBal) {
            IERC20(token).transfer(_to, tokenBal);
        } else {
            IERC20(token).transfer(_to, _amount);
        }
    }
}