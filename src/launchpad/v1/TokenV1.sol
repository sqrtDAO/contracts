// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Token
 * @dev Mints the total supply directly to `initialOwner`.
 */
contract TokenV1 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 totalSupply_, address initialOwner_)
        ERC20(name_, symbol_)
    {
        _mint(initialOwner_, totalSupply_);
    }
}
