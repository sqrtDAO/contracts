// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenV1 is ERC20 {
    /**
     * @param _name          Token name
     * @param _symbol        Token symbol
     * @param _allocations    Array of initial allocation structs (recipient + amount)
     */
    constructor(string memory _name, string memory _symbol, Allocation[] memory _allocations) ERC20(_name, _symbol) {
        uint256 totalSupply_ = 0;
        for (uint256 i = 0; i < _allocations.length; i++) {
            require(_allocations[i].recipient != address(0), "Invalid recipient");
            totalSupply_ += _allocations[i].amount;
            _mint(_allocations[i].recipient, _allocations[i].amount);
        }
        require(totalSupply_ > 0, "Total supply must be > 0");
    }
}

struct Allocation {
    address recipient;
    uint256 amount;
}
