// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FactoryV1} from "../src/v1/FactoryV1.sol";
import {FeeVault} from "src/utils/FeeVault.sol";
import {TokenV1Factory} from "../src/v1/TokenV1Factory.sol";
import {DistributionV1Factory} from "../src/v1/DistributionV1Factory.sol";
import {INonfungiblePositionManager} from "../src/external-interfaces/INonfungiblePositionManager.sol";
import {IPermit2} from "../src/external-interfaces/IPermit2.sol";
import {TransferToHook} from "src/utils/hooks/TransferToHook.sol";
import {BuyAndBurnHookV3} from "src/utils/hooks/BuyAndBurnHookV3.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract FeeVaultTest is Test {
    FactoryV1 public factory;
    FeeVault public vault;
    ERC20Mock public feeToken;
    ERC20Mock public otherToken;

    address public owner = address(0xCAFE);
    address public treasury = address(0x5AFE);
    address public user = address(0x1234);
    address public newOwner = address(0xFACE);

    function setUp() public {
        feeToken = new ERC20Mock();
        otherToken = new ERC20Mock();

        factory = new FactoryV1(
            owner,
            0,
            new TransferToHook(),
            new BuyAndBurnHookV3(address(0x0)),
            INonfungiblePositionManager(address(0x1)),
            IPermit2(address(0x2)),
            new TokenV1Factory(),
            new DistributionV1Factory(),
            new FeeVault(owner)
        );
        vault = factory.FEE_VAULT();
    }

    function testVaultIsCreatedByFactory() public view {
        assertEq(vault.owner(), owner, "vault owner must be the factory's initial owner");
    }

    function testCashOutRevertsForNonOwner() public {
        feeToken.mint(address(vault), 100 ether);
        vm.prank(user);
        vm.expectRevert(bytes("only owner"));
        vault.cashOut(address(feeToken), treasury, 100 ether);
    }

    function testOwnerCashsOutFullBalance() public {
        feeToken.mint(address(vault), 100 ether);
        vm.prank(owner);
        vault.cashOut(address(feeToken), treasury, 100 ether);

        assertEq(feeToken.balanceOf(address(vault)), 0);
        assertEq(feeToken.balanceOf(treasury), 100 ether);
    }

    function testCashOutDifferentTokensToDifferentDestinations() public {
        feeToken.mint(address(vault), 100 ether);
        otherToken.mint(address(vault), 50 ether);

        vm.startPrank(owner);
        vault.cashOut(address(feeToken), treasury, 100 ether);
        vault.cashOut(address(otherToken), user, 50 ether);
        vm.stopPrank();

        assertEq(feeToken.balanceOf(address(vault)), 0);
        assertEq(feeToken.balanceOf(treasury), 100 ether);
        assertEq(otherToken.balanceOf(address(vault)), 0);
        assertEq(otherToken.balanceOf(user), 50 ether);
    }

    function testVaultOwnerDoesNotFollowFactoryOwnershipTransfer() public {
        feeToken.mint(address(vault), 100 ether);

        vm.prank(owner);
        factory.transferOwnership(newOwner);

        // vault authority is fixed at deployment: the previous factory owner still controls it
        vm.prank(owner);
        vault.cashOut(address(feeToken), treasury, 100 ether);
        assertEq(feeToken.balanceOf(treasury), 100 ether);
    }

    function testCashOutRevertsWhenAmountExceedsBalance() public {
        feeToken.mint(address(vault), 50 ether);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 50 ether, 100 ether)
        );
        vault.cashOut(address(feeToken), treasury, 100 ether);
    }

    function testCraftedHookCannotCashOutVaultFunds() public {
        feeToken.mint(address(vault), 100 ether);
        CraftedCashOutHook craftedHook = new CraftedCashOutHook();

        // mimics DistributorV1 executing a user-crafted share hook: the distributor itself is
        // msg.sender for the cashOut call, so the owner check must reject it
        craftedHook.tryCashOut(vault, address(feeToken), address(craftedHook), 100 ether);

        assertFalse(craftedHook.succeeded(), "cashOut must fail when called by a non-owner");
        assertEq(feeToken.balanceOf(address(craftedHook)), 0);
        assertEq(feeToken.balanceOf(address(vault)), 100 ether, "vault balance untouched");
    }
}

/// @dev stands in for a user-crafted distributor share hook (HookLib.tryCall semantics: failures
///      are swallowed, never propagated to the release flow)
contract CraftedCashOutHook {
    bool public succeeded;

    function tryCashOut(FeeVault vault, address token, address to, uint256 amount) external {
        try vault.cashOut(token, to, amount) {
            succeeded = true;
        } catch {
            succeeded = false;
        }
    }
}
