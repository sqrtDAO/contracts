// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Range, ParticipateParams} from "./DistributorV1.sol";

/// @notice minimal view of `DistributorV1` needed by this router
/// @dev struct types are imported from `DistributorV1.sol` so the ABI encoding always stays in sync
interface IDistributorV1 {
    function participate(uint256 amountPerEpoch, Range memory range, address recipient, bytes memory allowlistSignature)
        external;
    function participateMany(ParticipateParams[] memory params) external;
}

/// @notice minimal wrapped-native interface (everything else is handled as a plain ERC-20)
interface IWETH {
    function deposit() external payable;
}

/// @title EthParticipationRouter
/// @notice Lets users participate in `DistributorV1` epoch distributions with native ETH.
/// @dev Wraps the sent ETH into WETH and immediately forwards it through the distributor's normal
///      ERC-20 `participate` flow, so distributors, shares and hooks stay completely untouched.
/// @dev Stateless and ownerless: funds are only held transiently within a single transaction and
///      normal operation leaves a zero balance.
/// @dev The `distributor` address is caller-chosen and cannot be verified — only pass legitimate
///      DistributorV1 addresses whose PARTICIPATION_TOKEN is this chain's wrapped-native token.
/// @dev From the distributor's point of view this router is `msg.sender`, so:
///      - participation is credited to the `recipient` you pass (never zero),
///      - `Participated` events show this router as the participant (index by recipient),
///      - allowlists are verified over the `recipient`, so allowlisted users pass their own
///        signature through `_allowlistSignature` / the params' `allowlistSignature` fields
///        and can participate with ETH while an allowlist is active
contract EthParticipationRouter {
    using SafeERC20 for IERC20;

    event ParticipatedWithETH(
        address indexed sender,
        address indexed distributor,
        address indexed recipient,
        uint256 fromEpoch,
        uint256 numEpochs,
        uint256 amountPerEpoch
    );
    event ETHSwept(address indexed to, uint256 amount);

    error IncorrectMsgValue(uint256 expected, uint256 sent);
    error ZeroRecipient();
    error ZeroWeth();
    error EmptyParams();

    /// @notice canonical wrapped-native token of the chain (e.g. WETH9)
    IWETH public immutable WETH;

    /// @param _weth canonical wrapped-native token of the chain (e.g. WETH9)
    constructor(address _weth) {
        if (_weth == address(0)) revert ZeroWeth();
        WETH = IWETH(_weth);
    }

    /**
     * @notice participate in epochs with native ETH
     * @dev `msg.value` must exactly equal `_range.length * _amountPerEpoch` — overpayment reverts
     *      and there is no refund logic
     * @param _distributor DistributorV1 whose PARTICIPATION_TOKEN is the wrapped-native token
     * @param _amountPerEpoch amount per epoch (in the wrapped-native token, 18 decimals like ETH)
     * @param _range epochs to participate in (see `DistributorV1.participate`)
     * @param _recipient address credited with the participation (the actual user, never zero)
     * @param _allowlistSignature if the distributor is allowlisted, ECDSA signature signed by its
     *        ALLOWLIST_SIGNER over keccak256(abi.encode(distributor, _recipient, chainId)); pass
     *        empty when the allowlist is disabled or expired
     */
    function participateWithETH(
        address _distributor,
        uint256 _amountPerEpoch,
        Range memory _range,
        address _recipient,
        bytes memory _allowlistSignature
    ) external payable {
        if (_recipient == address(0)) revert ZeroRecipient();
        uint256 total = _range.length * _amountPerEpoch;
        if (msg.value != total) revert IncorrectMsgValue(total, msg.value);

        WETH.deposit{value: msg.value}();
        IERC20 weth = IERC20(address(WETH));
        weth.forceApprove(_distributor, total);
        IDistributorV1(_distributor).participate(_amountPerEpoch, _range, _recipient, _allowlistSignature);
        weth.forceApprove(_distributor, 0);
        _refundLeftover(weth);

        emit ParticipatedWithETH(msg.sender, _distributor, _recipient, _range.from, _range.length, _amountPerEpoch);
    }

    /**
     * @notice calls `DistributorV1.participateMany` with native ETH
     * @dev `msg.value` must exactly equal the sum of all params' `range.length * amountPerEpoch`;
     *      each param's `allowlistSignature` is forwarded as-is (must cover that param's
     *      `recipient` when the distributor is allowlisted)
     * @param _distributor DistributorV1 whose PARTICIPATION_TOKEN is the wrapped-native token
     * @param _params participation params, each with an explicit `recipient` (never zero)
     */
    function participateManyWithETH(address _distributor, ParticipateParams[] memory _params) external payable {
        if (_params.length == 0) revert EmptyParams();

        uint256 total;
        for (uint256 i = 0; i < _params.length; i++) {
            if (_params[i].recipient == address(0)) revert ZeroRecipient();
            total += _params[i].range.length * _params[i].amountPerEpoch;
        }
        if (msg.value != total) revert IncorrectMsgValue(total, msg.value);

        WETH.deposit{value: msg.value}();
        IERC20 weth = IERC20(address(WETH));
        weth.forceApprove(_distributor, total);
        IDistributorV1(_distributor).participateMany(_params);
        weth.forceApprove(_distributor, 0);
        _refundLeftover(weth);

        for (uint256 i = 0; i < _params.length; i++) {
            emit ParticipatedWithETH(
                msg.sender,
                _distributor,
                _params[i].recipient,
                _params[i].range.from,
                _params[i].range.length,
                _params[i].amountPerEpoch
            );
        }
    }

    /// @notice anyone can sweep native ETH stuck in this contract (e.g. forced in via
    ///         `selfdestruct`; normal operation always leaves a zero balance)
    /// @dev deliberately no access control — the router is stateless and normally holds nothing
    function sweepETH(address payable _to) external {
        uint256 amount = address(this).balance;
        (bool success,) = _to.call{value: amount}("");
        require(success, "eth sweep failed");
        emit ETHSwept(_to, amount);
    }

    /// @dev refunds unconsumed wrapped-native tokens to the payer (e.g. a distributor that
    ///      pulled less than approved); never triggers in normal operation
    function _refundLeftover(IERC20 _weth) private {
        uint256 leftover = _weth.balanceOf(address(this));
        if (leftover != 0) {
            _weth.safeTransfer(msg.sender, leftover);
        }
    }
}
