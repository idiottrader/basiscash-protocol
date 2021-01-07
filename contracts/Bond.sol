pragma solidity ^0.6.0;

import './owner/Operator.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';

contract Bond is ERC20Burnable, Ownable, Operator {
    /**
     * @notice Constructs the Basis Bond ERC-20 contract.
     * @notice 发行BAB代币
     */
    constructor() public ERC20('BAB', 'BAB') {}

    /**
     * @notice Operator mints basis bonds to a recipient
     * @notice BAB代币的铸造方法
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis bonds to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_)
        public
        onlyOperator
        returns (bool)
    {
        uint256 balanceBefore = balanceOf(recipient_);
        //仅Operator有权限铸造
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    /**
     * @notice BAB代币的销毁方法，Operator有权限销毁
     */
    function burn(uint256 amount) public override onlyOperator {
        super.burn(amount);
    }

    /**
     * @notice BAB代币的销毁方法，Operator有权限销毁，配合approve使用
     */
    function burnFrom(address account, uint256 amount)
        public
        override
        onlyOperator
    {
        super.burnFrom(account, amount);
    }
}
