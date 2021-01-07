/**
 * Basis Cash Treasury合约
 * 实现功能：
 * 1.通过预言机获取BAC价格，根据BAC价格不同，用BAC购买BAB，或赎回BAB获得BAC
 * 2.根据BAC价格不同，增发BAC，并把新增发的BAC分配给fund treasury boardroom
 * 注解：TimBear 20210107
 */

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IOracle.sol';
import './interfaces/IBoardroom.sol';
import './interfaces/IBasisAsset.sol';
import './interfaces/ISimpleERCFund.sol';
import './lib/Babylonian.sol';
import './lib/FixedPoint.sol';
import './lib/Safe112.sol';
import './owner/Operator.sol';
import './utils/Epoch.sol';
import './utils/ContractGuard.sol';

/**
 * @title Basis Cash Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis cash assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, Epoch {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;
    using Safe112 for uint112;

    /* ========== STATE VARIABLES ========== */

    // ========== FLAGS
    bool public migrated = false;
    bool public initialized = false;

    // ========== CORE
    address public fund;
    address public cash;
    address public bond;
    address public share;
    address public boardroom;

    address public bondOracle;
    address public seigniorageOracle;

    // ========== PARAMS
    uint256 public cashPriceOne;
    uint256 public cashPriceCeiling;
    uint256 public bondDepletionFloor;
    uint256 private accumulatedSeigniorage = 0;
    uint256 public fundAllocationRate = 2; // %

    /* ========== CONSTRUCTOR ========== */
    /**
     *@notice 构造函数
     */
    constructor(
        address _cash,
        address _bond,
        address _share,
        address _bondOracle,
        address _seigniorageOracle,
        address _boardroom,
        address _fund,
        uint256 _startTime
    ) public Epoch(1 days, _startTime, 0) {
        cash = _cash;
        bond = _bond;
        share = _share;
        bondOracle = _bondOracle;
        seigniorageOracle = _seigniorageOracle;

        boardroom = _boardroom;
        fund = _fund;

        //基准价格为1
        cashPriceOne = 10**18;
        //cashPriceCeiling价格为1.05
        cashPriceCeiling = uint256(105).mul(cashPriceOne).div(10**2);
        bondDepletionFloor = uint256(1000).mul(cashPriceOne);
    }

    /* =================== Modifier =================== */

    //修饰符：需要完成Migration，即完成更换Operator为本合约
    modifier checkMigration {
        require(!migrated, 'Treasury: migrated');

        _;
    }

    //修饰符：合约cash bond share boardroom的Operator必须为本合约
    modifier checkOperator {
        require(
            IBasisAsset(cash).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            'Treasury: need more permission'
        );

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */
    //一些只读方法

    // budget
    function getReserve() public view returns (uint256) {
        return accumulatedSeigniorage;
    }

    // oracle
    function getBondOraclePrice() public view returns (uint256) {
        return _getCashPrice(bondOracle);
    }

    function getSeigniorageOraclePrice() public view returns (uint256) {
        return _getCashPrice(seigniorageOracle);
    }

    /**
     *notice:根据不同的场景选择不同的预言机进行喂价
     */
    function _getCashPrice(address oracle) internal view returns (uint256) {
        try IOracle(oracle).consult(cash, 1e18) returns (uint256 price) {
            return price;
        } catch {
            revert('Treasury: failed to consult cash price from the oracle');
        }
    }

    /* ========== GOVERNANCE ========== */
    
    /**
     *@notice 合约初始化
     */
    function initialize() public checkOperator {
        require(!initialized, 'Treasury: initialized');

        // burn all of it's balance
        // 销毁本合约所有BAC
        IBasisAsset(cash).burn(IERC20(cash).balanceOf(address(this)));

        // set accumulatedSeigniorage to it's balance
        // 设置累计储备量为本合约BAC数量的初始余额,即为0
        accumulatedSeigniorage = IERC20(cash).balanceOf(address(this));

        initialized = true;
        //触发合约初始化事件
        emit Initialized(msg.sender, block.number);
    }

    /**
      *@notice 更换Operator为target（本合约），仅现Operator有权更换 
      */
    function migrate(address target) public onlyOperator checkOperator {
        require(!migrated, 'Treasury: migrated');

        // cash
        //更换BAC合约的Operator，Owner为target，并把原合约的BAC发送至target
        Operator(cash).transferOperator(target);
        Operator(cash).transferOwnership(target);
        IERC20(cash).transfer(target, IERC20(cash).balanceOf(address(this)));

        // bond
        //更换BAB合约的Operator，Owner为target，并把原合约的BAB发送至target
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        //更换BAS合约的Operator，Owner为target，并把原合约的BAS发送至target
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        //触发所有权转移事件
        emit Migration(target);
    }

    function setFund(address newFund) public onlyOperator {
        //设置开发贡献者奖金池
        fund = newFund;
        //触发更换开发贡献者奖金池事件
        emit ContributionPoolChanged(msg.sender, newFund);
    }

    function setFundAllocationRate(uint256 rate) public onlyOperator {
        //设置开发贡献者奖金比例
        fundAllocationRate = rate;
        //触发更换开发贡献者奖金比例事件
        emit ContributionPoolRateChanged(msg.sender, rate);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    /**
      *@notice 通过预言机获取BAC价格 
      */
    function _updateCashPrice() internal {
        try IOracle(bondOracle).update()  {} catch {}
        try IOracle(seigniorageOracle).update()  {} catch {}
    }

    /**
      *@notice 当BAC价格低于1时，使用BAC购买BAB 
      */
    function buyBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot purchase bonds with zero amount');

        //通过预言机获取BAC价格
        uint256 cashPrice = _getCashPrice(bondOracle);
        //BAC价格必须等于目标价格
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        //需要BAC价格小于1
        require(
            cashPrice < cashPriceOne, // price < $1
            'Treasury: cashPrice not eligible for bond purchase'
        );

        uint256 bondPrice = cashPrice;
        //销毁BAC
        IBasisAsset(cash).burnFrom(msg.sender, amount);
        //铸造BAB: 销毁1BAC能换取(1/bondPrice)个BAB
        IBasisAsset(bond).mint(msg.sender, amount.mul(1e18).div(bondPrice));
        //更新BAC价格
        _updateCashPrice();
        //触发购买BAB事件
        emit BoughtBonds(msg.sender, amount);
    }

    /**
      *@notice 当BAC价格大于1.05时，使用BAB换回BAC
      */ 
    function redeemBonds(uint256 amount, uint256 targetPrice)
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkOperator
    {
        require(amount > 0, 'Treasury: cannot redeem bonds with zero amount');
        
        //通过预言机获取BAC价格
        uint256 cashPrice = _getCashPrice(bondOracle);
        //BAC价格必须等于目标价格
        require(cashPrice == targetPrice, 'Treasury: cash price moved');
        //需要BAC价格大于cashPriceCeiling，即1.05
        require(
            cashPrice > cashPriceCeiling, // price > $1.05
            'Treasury: cashPrice not eligible for bond purchase'
        );
        //需要本合约的BAC数量大于要赎回的BAB数量
        require(
            IERC20(cash).balanceOf(address(this)) >= amount,
            'Treasury: treasury has no more budget'
        );
        //累计储备量 = 累计储备量 - 要赎回的BAB数量,即1BAB换取1BAC
        accumulatedSeigniorage = accumulatedSeigniorage.sub(
            Math.min(accumulatedSeigniorage, amount)
        );
        
        //销毁BAB
        IBasisAsset(bond).burnFrom(msg.sender, amount);
        //发送BAC
        IERC20(cash).safeTransfer(msg.sender, amount);
        //更新BAC价格
        _updateCashPrice();
         
        //触发赎回BAB事件
        emit RedeemedBonds(msg.sender, amount);
    }

    /**
      *@notice 增发BAC，并分配BAC 
      */ 
    function allocateSeigniorage()
        external
        onlyOneBlock
        checkMigration
        checkStartTime
        checkEpoch
        checkOperator
    {
        //更新BAC价格
        _updateCashPrice();
        uint256 cashPrice = _getCashPrice(seigniorageOracle);
        //判断当BAC价格小于等于cashPriceCeiling即1.05则返回，不增发BAC
        if (cashPrice <= cashPriceCeiling) {
            return; // just advance epoch instead revert
        }

        // circulating supply
        //流通的BAC数量 = BAC总供应量 - 累计储备量
        uint256 cashSupply = IERC20(cash).totalSupply().sub(
            accumulatedSeigniorage
        );
        //增发比例 = BAC价格 - 1
        uint256 percentage = cashPrice.sub(cashPriceOne);
        //新铸造的BAC数量 = 流通的BAC数量 * 增发比例
        uint256 seigniorage = cashSupply.mul(percentage).div(1e18);
        //新铸造BAC,并发送至本合约
        IBasisAsset(cash).mint(address(this), seigniorage);

        // ======================== BIP-3
        //基金储备 = 新铸造的BAC数量 * fundAllocationRate / 100 = 新铸造的BAC数量 * 2% 
        uint256 fundReserve = seigniorage.mul(fundAllocationRate).div(100);
        if (fundReserve > 0) {
            IERC20(cash).safeApprove(fund, fundReserve);
            ISimpleERCFund(fund).deposit(
                cash,
                fundReserve,
                'Treasury: Seigniorage Allocation'
            );
            //触发BAC已发放至开发贡献池事件
            emit ContributionPoolFunded(now, fundReserve);
        }
        //新铸造的BAC数量 = 新铸造的BAC数量 - 基金储备
        seigniorage = seigniorage.sub(fundReserve);

        // ======================== BIP-4
        //新增国库储备 = min(新铸造的BAC数量, BAB总供应量-累计BAC储备量)
        //即新铸造的BAC要先预留给BAB，剩下的才能分配给Boardroom
        uint256 treasuryReserve = Math.min(
            seigniorage,
            IERC20(bond).totalSupply().sub(accumulatedSeigniorage)
        );
        if (treasuryReserve > 0) {
            //累计BAC储备量 = 累计BAC储备量 + 新增国库储备量
            accumulatedSeigniorage = accumulatedSeigniorage.add(
                treasuryReserve
            );
            //触发已发放国库储备事件
            emit TreasuryFunded(now, treasuryReserve);
        }

        // boardroom
        //董事会BAC新增储备量 = 新铸造的BAC - 新增国库储备量
        uint256 boardroomReserve = seigniorage.sub(treasuryReserve);
        if (boardroomReserve > 0) {
            IERC20(cash).safeApprove(boardroom, boardroomReserve);
            //调用Boardroom合约的allocateSeigniorage方法
            IBoardroom(boardroom).allocateSeigniorage(boardroomReserve);
            //触发已发放资金至董事会事件
            emit BoardroomFunded(now, boardroomReserve);
        }
    }

    // GOV
    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event ContributionPoolChanged(address indexed operator, address newFund);
    event ContributionPoolRateChanged(
        address indexed operator,
        uint256 newRate
    );

    // CORE
    event RedeemedBonds(address indexed from, uint256 amount);
    event BoughtBonds(address indexed from, uint256 amount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event ContributionPoolFunded(uint256 timestamp, uint256 seigniorage);
}
