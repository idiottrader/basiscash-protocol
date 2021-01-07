pragma solidity ^0.6.0;

import './owner/Operator.sol';
import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';

contract Share is ERC20Burnable, Operator {
    /**
     * @notice Constructs the Basis Share ERC-20 contract.
     * @notice 发行BAS代币
     */
    constructor() public ERC20('BAS', 'BAS') {
        // Mints 1 Basis Share to contract creator for initial Uniswap oracle deployment.
        // Will be burned after oracle deployment
        _mint(msg.sender, 1 * 10**18);
    }

    /**
     * @notice Operator mints basis cash to a recipient
     * @notice BAS代币的铸造方法，仅Operator有权铸造
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis cash to mint to
     */
    function mint(address recipient_, uint256 amount_)
        public
        onlyOperator
        returns (bool)
    {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);
        return balanceAfter >= balanceBefore;
    }

    /**
     * @notice BAS代币的销毁方法，仅Operator有权销毁
     */
    function burn(uint256 amount) public override onlyOperator {
        super.burn(amount);
    }

    /**
     * @notice BAS代币的销毁方法，仅Operator有权销毁，配合approve一起使用
     */
    function burnFrom(address account, uint256 amount)
        public
        override
        onlyOperator
    {
        super.burnFrom(account, amount);
    }
}
