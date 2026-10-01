// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title FeeVault
/// @notice Custodian of the protocol fee. Deployed by the deployer script and passed into
///         FactoryV1's constructor (which stores it immutably), so its address is fixed forever:
///         the fee share calldata baked into every distributor always routes here, even when the
///         cash-out destination changes later (previously-launched distributions are never
///         affected by where the owner ultimately sends the fees).
/// @dev Deliberately minimal — there is no function that lets anyone spend the vault's balances
///      except the owner-gated `cashOut`. Authority is the vault's own owner, fixed at deployment
///      to the factory's initial owner: it does NOT follow later `FactoryV1.transferOwnership`
///      calls. Keeping fees here instead of in FactoryV1 means the permissionless
///      `createDistributor(_pullIn = false)` flow (which moves FactoryV1-held tokens into a
///      caller-owned distributor) can never touch the collected fees.
contract FeeVault is Ownable {
    using SafeERC20 for IERC20;

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    /// @param _token token to cash out (fee is in participation token so it can be anything)
    /// @param _to where funds should be transfer to
    /// @param _amount amount of token to transfer
    function cashOut(address _token, address _to, uint256 _amount) external {
        require(msg.sender == owner(), "only owner");
        IERC20(_token).safeTransfer(_to, _amount);
    }
}
