pragma solidity ^0.6.0;
/**
 *Submitted for verification at Etherscan.io on 2020-07-17
 */

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: BASISCASHRewards.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

// File: @openzeppelin/contracts/math/Math.sol

import '@openzeppelin/contracts/math/Math.sol';

// File: @openzeppelin/contracts/math/SafeMath.sol

import '@openzeppelin/contracts/math/SafeMath.sol';

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

// File: @openzeppelin/contracts/utils/Address.sol

import '@openzeppelin/contracts/utils/Address.sol';

// File: @openzeppelin/contracts/token/ERC20/SafeERC20.sol

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

// File: contracts/IRewardDistributionRecipient.sol

import '../interfaces/IRewardDistributionRecipient.sol';

/**
 * Basis Cash BACDAIPool合约
 * 实现功能：
 * 1.BACDAIPool,挖矿池，抵押DAI收获BAC
 * 2.计算BAC生成发放的规则
 * 注解：TimBear 20210107
 */

contract DAIWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public dai;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     *@notice 抵押DAI进池子
     */
    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        dai.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     *@notice 从池子中取出DAI
     */
    function withdraw(uint256 amount) public virtual {
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        dai.safeTransfer(msg.sender, amount);
    }
}

contract BACDAIPool is DAIWrapper, IRewardDistributionRecipient {
    IERC20 public basisCash;
    //DAI池挖矿周期为5天
    uint256 public DURATION = 5 days;

    uint256 public starttime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public deposits;

    //触发事件：奖励增加 抵押 取款 奖励发放
    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    //构造函数
    constructor(
        address basisCash_,
        address dai_,
        uint256 starttime_
    ) public {
        basisCash = IERC20(basisCash_);
        dai = IERC20(dai_);
        starttime = starttime_;
    }

    //修饰符：满足开始时间
    modifier checkStart() {
        require(block.timestamp >= starttime, 'BACDAIPool: not start');
        _;
    }

    //修饰符：更新账户奖励
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    /**
     *@notice 抵押DAI进池子
     */
    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkStart
    {
        require(amount > 0, 'BACDAIPool: Cannot stake 0');
        uint256 newDeposit = deposits[msg.sender].add(amount);
        //限制每个账户抵押总量不超过20000DAI
        require(
            newDeposit <= 20000e18,
            'BACDAIPool: deposit amount exceeds maximum 20000'
        );
        deposits[msg.sender] = newDeposit;
        super.stake(amount);
        //触发抵押事件
        emit Staked(msg.sender, amount);
    }

    /**
     *@notice 从池子中取出DAI
     */
    function withdraw(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkStart
    {
        require(amount > 0, 'BACDAIPool: Cannot withdraw 0');
        deposits[msg.sender] = deposits[msg.sender].sub(amount);
        super.withdraw(amount);
        //触发取款事件
        emit Withdrawn(msg.sender, amount);
    }

    /**
     *@notice 从池子中取出DAI,并取出奖励
     */
    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    /**
     *@notice 取出奖励
     */
    function getReward() public updateReward(msg.sender) checkStart {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            //挖矿奖励为BAC，发送至合约调用者
            basisCash.safeTransfer(msg.sender, reward);
            //触发发送奖励事件
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     *@notice 
     */
    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyRewardDistribution
        updateReward(address(0))
    {
        if (block.timestamp > starttime) {
            if (block.timestamp >= periodFinish) {
                rewardRate = reward.div(DURATION);
            } else {
                uint256 remaining = periodFinish.sub(block.timestamp);
                uint256 leftover = remaining.mul(rewardRate);
                rewardRate = reward.add(leftover).div(DURATION);
            }
            lastUpdateTime = block.timestamp;
            periodFinish = block.timestamp.add(DURATION);
            emit RewardAdded(reward);
        } else {
            rewardRate = reward.div(DURATION);
            lastUpdateTime = starttime;
            periodFinish = starttime.add(DURATION);
            emit RewardAdded(reward);
        }
    }
}
