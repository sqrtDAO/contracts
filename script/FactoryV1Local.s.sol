// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TransferToHook} from "../src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager, MintParams} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {IUniswapV3SwapRouter, ExactInputParams} from "../src/external-interfaces/IUniswapV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FactoryV1LocalScript is Script {
    function run() external returns (FactoryV1 factory) {
        uint256 pk =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        vm.startBroadcast(pk);

        MockPermit2 permit2 = new MockPermit2();
        MockPositionManager positionManager = new MockPositionManager();
        MockSwapRouter swapRouter = new MockSwapRouter();

        factory = new FactoryV1(
            msg.sender,
            0,
            msg.sender,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(swapRouter)),
            INonfungiblePositionManager(address(positionManager)),
            IPermit2(address(permit2))
        );

        vm.stopBroadcast();
    }
}

contract MockPermit2 is IPermit2 {
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    ) external override {
        IERC20(permit.permitted.token).transferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
    }
}

contract MockPositionManager {
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external view returns (address) {
        return address(this);
    }

    function mint(MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
        return (1, 1, params.amount0Desired, params.amount1Desired);
    }
}

contract MockSwapRouter {
    function exactInput(ExactInputParams calldata params) external returns (uint256 amountOut) {
        bytes calldata path = params.path;
        address tokenIn;
        assembly {
            tokenIn := calldataload(path.offset)
        }
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn;
        IERC20(tokenIn).transfer(params.recipient, amountOut);
    }
}
