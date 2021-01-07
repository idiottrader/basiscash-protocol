pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol';
import './owner/Operator.sol';

contract Cash is ERC20Burnable, Operator {
    /**
     * @notice Constructs the Basis Cash ERC-20 contract.
     * @notice 发行BAC代币
     */
    constructor() public ERC20('BAC', 'BAC') {
        // Mints 1 Basis Cash to contract creator for initial Uniswap oracle deployment.
        // Will be burned after oracle deployment
        _mint(msg.sender, 1 * 10**18);
    }

    //    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    //        super._beforeTokenTransfer(from, to, amount);
    //        require(
    //            to != operator(),
    //            "basis.cash: operator as a recipient is not allowed"
    //        );
    //    }

    /**
     * @notice Operator mints basis cash to a recipient
     * @notice BAC代币的铸造方法
     * @param recipient_ The address of recipient
     * @param amount_ The amount of basis cash to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_)
        public
        onlyOperator
        returns (bool)
    {
        uint256 balanceBefore = balanceOf(recipient_);
        //仅Operator有权限铸造，并发送给recipient_
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    /**
     * @notice BAC代币的销毁方法，仅Operato有权限销毁
     */
    function burn(uint256 amount) public override onlyOperator {
        super.burn(amount);
    }

    /**
     * @notice BAC代币的销毁方法，仅Operato有权限销毁，配合approve方法一起用
     */
    function burnFrom(address account, uint256 amount)
        public
        override
        onlyOperator
    {
        super.burnFrom(account, amount);
    }
}
