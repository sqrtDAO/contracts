// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {TransferToHook} from "../src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {INonfungiblePositionManager, MintParams} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {IUniswapV3SwapRouter, ExactInputParams} from "../src/external-interfaces/IUniswapV3SwapRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedEmission} from "../src/utils/emission-function/FixedEmission.sol";
import {LinearEmission} from "../src/utils/emission-function/LinearEmission.sol";
import {ExponentialEmission} from "../src/utils/emission-function/ExponentialEmission.sol";
import {TokenV1, Allocation} from "../src/v1/TokenV1.sol";

contract FactoryV1LocalScript is Script {
    function run() external returns (FactoryV1 factory) {
        uint256 pk =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        vm.startBroadcast(pk);

        // EmissionFunctions
        FixedEmission fixedEmission = new FixedEmission();
        LinearEmission linearEmission = new LinearEmission();
        ExponentialEmission exponentialEmission = new ExponentialEmission();

        // Mock
        MockPermit2 permit2 = new MockPermit2();
        MockPositionManager positionManager = new MockPositionManager();
        MockSwapRouter swapRouter = new MockSwapRouter();

        // Hooks
        TransferToHook transferToHook = new TransferToHook();
        BuyAndBurnHookV3 buyAndBurnHook = new BuyAndBurnHookV3(address(swapRouter));

        // Child deployers
        TokenV1Factory tokenFactory = new TokenV1Factory();
        DistributionV1Factory distributorFactory = new DistributionV1Factory();

        factory = new FactoryV1(
            msg.sender,
            400, // 4%
            transferToHook,
            buyAndBurnHook,
            INonfungiblePositionManager(address(positionManager)),
            IPermit2(address(permit2)),
            tokenFactory,
            distributorFactory
        );

        // fake token to use as participation token
        Allocation[] memory allocation = new Allocation[](1);
        allocation[0] = Allocation({recipient: address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266), amount: 1000 ether});
        TokenV1 fakeUSD = new TokenV1("Fake USD", "FUSD", allocation);

        console.log("fakeUSD", address(fakeUSD));

        console.log("fixedEmission", address(fixedEmission));
        console.log("linearEmission", address(linearEmission));
        console.log("exponentialEmission", address(exponentialEmission));
        console.log("transferToHook", address(transferToHook));
        console.log("buyAndBurnHook", address(buyAndBurnHook));

        console.log("permit2", address(permit2));
        console.log("positionManager", address(positionManager));
        console.log("swapRouter", address(swapRouter));

        console.log("tokenFactory", address(tokenFactory));
        console.log("distributorFactory", address(distributorFactory));

        console.log("factoryV1", address(factory));

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
