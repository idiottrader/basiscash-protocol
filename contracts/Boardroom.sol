/**
 * Basis Cash Boardroom合约
 * 实现功能：
 * 1.BAS抵押到Boardroom，从Boardroom赎回BAS
 * 2.每次Epoch时，Operator计算BAC增发的数量(计算公式在Treasury合约)，并把BAC奖励分配给把BAS抵押到Boardroom的董事
 * 注解：TimBear 20210107
 */

pragma solidity ^0.6.0;
//pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import './lib/Safe112.sol';
import './owner/Operator.sol';
import './utils/ContractGuard.sol';
import './interfaces/IBasisAsset.sol';

contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public share;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /**
     *@notice 把BAS抵押到Boardroom
     */
    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        share.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     *@notice 从Boardroom赎回BAS
     */
    function withdraw(uint256 amount) public virtual {
        uint256 directorShare = _balances[msg.sender];
        require(
            directorShare >= amount,
            'Boardroom: withdraw request greater than staked amount'
        );
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = directorShare.sub(amount);
        share.safeTransfer(msg.sender, amount);
    }
}

contract Boardroom is ShareWrapper, ContractGuard, Operator {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== DATA STRUCTURES ========== */

    //结构体：董事会席位
    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
    }

    //结构体：董事会快照
    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 private cash;

    //映射：每个地址对应每个董事会席位，即一个地址对应一个董事(结构体)
    mapping(address => Boardseat) private directors;
    BoardSnapshot[] private boardHistory;

    /* ========== CONSTRUCTOR ========== */

    /**
     *@notice 构造函数
     */
    constructor(IERC20 _cash, IERC20 _share) public {
        cash = _cash;
        share = _share;

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: 0,
            rewardPerShare: 0
        });
        //董事会的创世快照
        boardHistory.push(genesisSnapshot);
    }

    /* ========== Modifiers =============== */
    //修饰符：需要调用者抵押在Boardroom的BAS大于0
    modifier directorExists {
        require(
            balanceOf(msg.sender) > 0,
            'Boardroom: The director does not exist'
        );
        _;
    }

    //修饰符：更新每个董事的奖励(BAC)
    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters
    // 一些只读方法：获取快照信息

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director)
        public
        view
        returns (uint256)
    {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director)
        internal
        view
        returns (BoardSnapshot memory)
    {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    // =========== Director getters

    /**
     *@notice 获取最新快照中每个BAS可奖励的BAC
     */
    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    /**
     *@notice 计算董事可提取的总奖励(BAC)
     */
    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return
            balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(
                directors[director].rewardEarned
            );
    //董事可提取的总奖励 = 董事抵押的BAS个数*（最新快照中每BAS可获得的BAC数量-上次快照中每BAS可获得的BAC数量)+董事未提取的奖励
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     *@notice 把BAS抵押到Boardroom
     */
    function stake(uint256 amount)
        public
        override
        onlyOneBlock
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot stake 0');
        super.stake(amount);
        //触发抵押事件
        emit Staked(msg.sender, amount);
    }

    /**
     *@notice 从Boardroom赎回BAS
     */
    function withdraw(uint256 amount)
        public
        override
        onlyOneBlock
        directorExists
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot withdraw 0');
        super.withdraw(amount);
        //触发赎回事件
        emit Withdrawn(msg.sender, amount);
    }

    /**
     *@notice 从Boardroom赎回BAS，并提取奖励
     */
    function exit() external {
        withdraw(balanceOf(msg.sender));
        claimReward();
    }

    /**
     *@notice 从Boardroom收获奖励，奖励为BAC
     */
    function claimReward() public updateReward(msg.sender) {
        //更新董事的奖励后，获取奖励数量
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0) {
            directors[msg.sender].rewardEarned = 0;
            //把奖励数量重设为0
            cash.safeTransfer(msg.sender, reward);
            //把奖励发送给董事
            emit RewardPaid(msg.sender, reward);
            //触发完成奖励事件
        }
    }

    /**
     *@notice 分配铸币，即分配每个BAS可以获取多少BAC，仅Operator有权限控制
     *@notice 每Epoch增发多少BAC只由Operator决定,具体计算公式在Treasury合约
     */
    function allocateSeigniorage(uint256 amount)
        external
        onlyOneBlock
        onlyOperator
    {
        require(amount > 0, 'Boardroom: Cannot allocate 0');
        require(
            totalSupply() > 0,
            'Boardroom: Cannot allocate when totalSupply is 0'
        );

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        //prevRPS: 上次的快照中，每个BAS可奖励的BAC数量
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));
        //nextRPS：下一次快照中，每个BAS可奖励的BAC数量=上次快照中每个BAS可奖励的BAC数量+（本次增发至董事会的BAC总数量/ BAS的总供应量）
        //注意：每次快照记录的都为总量(累积量)，计算每Epoch新奖励的数量时要用增量(做减法)

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        //更新快照
        boardHistory.push(newSnapshot);

        //把增发的BAC数量发送到本合约中，增发数量由Operator决定
        cash.safeTransferFrom(msg.sender, address(this), amount);
        //触发BAC增发至董事会事件
        emit RewardAdded(msg.sender, amount);
    }

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
}
