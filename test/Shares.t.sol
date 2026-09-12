// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SharesLib, Share} from "../src/utils/Shares.sol";
import {HookLib, Hook, HookFailure} from "../src/utils/Hook.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract SharesConsumer {
    using SharesLib for Share;
    using SharesLib for Share[];

    function validateShares(Share[] calldata shares) external pure {
        shares.validateShares();
    }

    function shareOf(Share calldata share, uint256 amount) external pure returns (uint256) {
        return share.shareOf(amount);
    }

    function approveAndCall(Share calldata share, ERC20Mock asset, uint256 totalAmount)
        external
        returns (bytes memory)
    {
        asset.mint(address(this), totalAmount);
        return share.approveAndCall(asset, totalAmount);
    }

    function approveAndTryCall(Share calldata share, ERC20Mock asset, uint256 totalAmount)
        external
        returns (uint256 remainingAllowance)
    {
        asset.mint(address(this), totalAmount);
        share.approveAndTryCall(asset, totalAmount);
        return asset.allowance(address(this), share.hook.contractAddress);
    }
}

contract HookConsumer {
    function hookCall(Hook calldata hook) external returns (bytes memory) {
        return HookLib.call(hook);
    }

    function tryCall(Hook calldata hook) external returns (bool, bytes memory) {
        return HookLib.tryCall(hook);
    }
}

contract SharesTest is Test {
    SharesConsumer public consumer;
    HookConsumer public hookConsumer;
    ERC20Mock public asset;

    function setUp() public {
        consumer = new SharesConsumer();
        hookConsumer = new HookConsumer();
        asset = new ERC20Mock();
    }

    // --- shareOf ---
    function test_shareOf_full() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 10000, hook: Hook({contractAddress: address(0), callData: ""})}), 1000),
            1000
        );
    }

    function test_shareOf_half() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 5000, hook: Hook({contractAddress: address(0), callData: ""})}), 1000),
            500
        );
    }

    function test_shareOf_quarter() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 2500, hook: Hook({contractAddress: address(0), callData: ""})}), 1000),
            250
        );
    }

    function test_shareOf_zero() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 5000, hook: Hook({contractAddress: address(0), callData: ""})}), 0), 0
        );
    }

    function test_shareOf_zeroBps() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 0, hook: Hook({contractAddress: address(0), callData: ""})}), 1000), 0
        );
    }

    function test_shareOf_roundsDown() public {
        assertEq(
            consumer.shareOf(Share({shareBps: 1, hook: Hook({contractAddress: address(0), callData: ""})}), 9999), 0
        );
    }

    // --- validateShares ---
    function test_validateShares_single100() public {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10000, hook: Hook({contractAddress: address(0), callData: ""})});
        consumer.validateShares(shares);
    }

    function test_validateShares_twoHalves() public {
        Share[] memory shares = new Share[](2);
        shares[0] = Share({shareBps: 5000, hook: Hook({contractAddress: address(0), callData: ""})});
        shares[1] = Share({shareBps: 5000, hook: Hook({contractAddress: address(0), callData: ""})});
        consumer.validateShares(shares);
    }

    function test_validateShares_threeParts() public {
        Share[] memory shares = new Share[](3);
        shares[0] = Share({shareBps: 5000, hook: Hook({contractAddress: address(0), callData: ""})});
        shares[1] = Share({shareBps: 2500, hook: Hook({contractAddress: address(0), callData: ""})});
        shares[2] = Share({shareBps: 2500, hook: Hook({contractAddress: address(0), callData: ""})});
        consumer.validateShares(shares);
    }

    function test_validateShares_revertsIfOver() public {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 10001, hook: Hook({contractAddress: address(0), callData: ""})});
        vm.expectRevert(SharesLib.SharesNot100Percent.selector);
        consumer.validateShares(shares);
    }

    function test_validateShares_revertsIfUnder() public {
        Share[] memory shares = new Share[](1);
        shares[0] = Share({shareBps: 9999, hook: Hook({contractAddress: address(0), callData: ""})});
        vm.expectRevert(SharesLib.SharesNot100Percent.selector);
        consumer.validateShares(shares);
    }

    function test_validateShares_revertsIfEmpty() public {
        Share[] memory shares = new Share[](0);
        vm.expectRevert(SharesLib.SharesNot100Percent.selector);
        consumer.validateShares(shares);
    }

    // --- approveAndCall ---
    function test_approveAndCall_callsHook() public {
        DummyHook hookContract = new DummyHook();
        Share memory share = Share({shareBps: 5000, hook: Hook({contractAddress: address(hookContract), callData: ""})});

        consumer.approveAndCall(share, asset, 1000);

        assertTrue(hookContract.called());
    }

    function test_approveAndCall_resetsAllowance() public {
        DummyHook hookContract = new DummyHook();
        Share memory share = Share({shareBps: 5000, hook: Hook({contractAddress: address(hookContract), callData: ""})});

        consumer.approveAndCall(share, asset, 1000);

        assertEq(asset.allowance(address(consumer), address(hookContract)), 0);
    }

    function test_approveAndCall_correctAllowance() public {
        PullingHook hookContract = new PullingHook(address(asset));
        Share memory share = Share({
            shareBps: 5000,
            hook: Hook({contractAddress: address(hookContract), callData: abi.encodeWithSignature("pull()")})
        });

        consumer.approveAndCall(share, asset, 1000);

        assertEq(hookContract.pulled(), 500);
    }

    function test_approveAndCall_revertsOnHookRevert() public {
        RevertingHook hookContract = new RevertingHook();
        Share memory share = Share({shareBps: 5000, hook: Hook({contractAddress: address(hookContract), callData: ""})});

        vm.expectRevert(abi.encodeWithSelector(HookLib.HookReverted.selector, ""));
        consumer.approveAndCall(share, asset, 1000);
    }

    // --- approveAndTryCall ---
    function test_approveAndTryCall_success() public {
        DummyHook hookContract = new DummyHook();
        Share memory share =
            Share({shareBps: 10000, hook: Hook({contractAddress: address(hookContract), callData: ""})});

        uint256 remaining = consumer.approveAndTryCall(share, asset, 1000);

        assertTrue(hookContract.called());
        assertEq(remaining, 0);
    }

    function test_approveAndTryCall_emitsOnFailure() public {
        RevertingHook hookContract = new RevertingHook();
        Share memory share =
            Share({shareBps: 10000, hook: Hook({contractAddress: address(hookContract), callData: ""})});

        vm.expectEmit(true, true, true, true);
        emit HookFailure("");
        uint256 remaining = consumer.approveAndTryCall(share, asset, 1000);

        assertEq(remaining, 0);
    }

    // --- HookLib.call ---
    function test_hookCall_success() public {
        DummyHook hookContract = new DummyHook();
        Hook memory hook = Hook({contractAddress: address(hookContract), callData: ""});

        bytes memory returnData = hookConsumer.hookCall(hook);

        assertTrue(hookContract.called());
        assertEq(returnData, "");
    }

    function test_hookCall_revertsOnFailure() public {
        RevertingHook hookContract = new RevertingHook();
        Hook memory hook = Hook({contractAddress: address(hookContract), callData: ""});

        vm.expectRevert(abi.encodeWithSelector(HookLib.HookReverted.selector, ""));
        hookConsumer.hookCall(hook);
    }

    // --- HookLib.tryCall ---
    function test_tryCall_success() public {
        DummyHook hookContract = new DummyHook();
        Hook memory hook = Hook({contractAddress: address(hookContract), callData: ""});

        (bool success, bytes memory returnData) = hookConsumer.tryCall(hook);

        assertTrue(success);
        assertTrue(hookContract.called());
        assertEq(returnData, "");
    }

    function test_tryCall_emitsOnFailure() public {
        RevertingHook hookContract = new RevertingHook();
        Hook memory hook = Hook({contractAddress: address(hookContract), callData: ""});

        vm.expectEmit(true, true, true, true);
        emit HookFailure("");
        (bool success, bytes memory returnData) = hookConsumer.tryCall(hook);

        assertFalse(success);
        assertEq(returnData, "");
    }
}

contract DummyHook {
    bool private _called;

    function called() external view returns (bool) {
        return _called;
    }

    fallback() external {
        _called = true;
    }
}

contract RevertingHook {
    fallback() external {
        assembly { revert(0, 0) }
    }
}

contract PullingHook {
    uint256 public pulled;
    address public token;

    constructor(address _token) {
        token = _token;
    }

    function pull() external {
        uint256 allowance = ERC20Mock(token).allowance(msg.sender, address(this));
        if (allowance > 0) {
            require(ERC20Mock(token).transferFrom(msg.sender, address(this), allowance));
            pulled += allowance;
        }
    }
}
