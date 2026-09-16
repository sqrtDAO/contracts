// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedEmission, FixedEmissionConfig} from "../src/utils/emission-function/FixedEmission.sol";
import {LinearEmission, LinearEmissionConfig} from "../src/utils/emission-function/LinearEmission.sol";
import {ExponentialEmission, ExponentialEmissionConfig} from "../src/utils/emission-function/ExponentialEmission.sol";
import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";
import {EmissionFunction} from "../src/utils/emission-function/EmissionFunction.sol";

/// @notice Reference implementations that loop over every epoch, used as ground truth
contract LoopReferences {
    function loopTotal(IEmissionFunction emission, bytes memory config, uint256 numEpochs)
        external
        view
        returns (uint256 total)
    {
        for (uint256 i = 0; i < numEpochs; i++) {
            total += emission.calculate(config, i);
        }
    }
}

contract EmissionTotalTest is Test {
    LoopReferences loopRef;

    FixedEmission fixedEmission;
    LinearEmission linearEmission;
    ExponentialEmission exponentialEmission;

    function setUp() public {
        loopRef = new LoopReferences();
        fixedEmission = new FixedEmission();
        linearEmission = new LinearEmission();
        exponentialEmission = new ExponentialEmission();
    }

    // ============================================================
    // FixedEmission
    // ============================================================

    function testFixedTotalZeroEpochs() public view {
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: 100 ether}));
        assertEq(fixedEmission.calculateTotal(conf, 0), 0);
    }

    function testFixedTotalSingleEpoch() public view {
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: 100 ether}));
        assertEq(fixedEmission.calculateTotal(conf, 1), 100 ether);
    }

    function testFixedTotalExact() public view {
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: 100 ether}));
        // 100 epochs of 100 ether = 10_000 ether, exact answer
        assertEq(fixedEmission.calculateTotal(conf, 100), 10_000 ether);
    }

    function testFixedTotalZeroAmount() public view {
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: 0}));
        assertEq(fixedEmission.calculateTotal(conf, 1000), 0);
    }

    function testFixedTotalMatchesLoop(uint256 amount, uint256 numEpochs) public view {
        amount = bound(amount, 0, 1e30);
        numEpochs = bound(numEpochs, 0, 1000);
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: amount}));
        assertEq(fixedEmission.calculateTotal(conf, numEpochs), loopRef.loopTotal(fixedEmission, conf, numEpochs));
    }

    // ============================================================
    // LinearEmission
    // ============================================================

    function testLinearTotalZeroEpochs() public view {
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 100 ether, slope: 5 ether}));
        assertEq(linearEmission.calculateTotal(conf, 0), 0);
    }

    function testLinearTotalZeroSlope() public view {
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 100 ether, slope: 0}));
        assertEq(linearEmission.calculateTotal(conf, 50), 50 * 100 ether);
    }

    function testLinearTotalPositiveSlopeKnown() public view {
        // rewards: 100, 105, 110, ..., 100 + 5*9 -> sum = 10*100 + 5*(0+1+...+9) = 1000 + 225 = 1225
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 100 ether, slope: 5 ether}));
        assertEq(linearEmission.calculateTotal(conf, 10), 1225 ether);
    }

    function testLinearTotalNegativeSlopeNoClamp() public view {
        // rewards: 1000, 900, 800, 700 -> sum = 3400
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 1000 ether, slope: -100 ether}));
        assertEq(linearEmission.calculateTotal(conf, 4), 3400 ether);
    }

    function testLinearTotalNegativeSlopeExactClampBoundary() public view {
        // base = 1000, slope = -250: rewards 1000, 750, 500, 250, 0, 0, ...
        // exactly 4 positive epochs: sum = 2500
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 1000 ether, slope: -250 ether}));
        assertEq(linearEmission.calculateTotal(conf, 4), 2500 ether);
        assertEq(linearEmission.calculateTotal(conf, 5), 2500 ether);
        assertEq(linearEmission.calculateTotal(conf, 100), 2500 ether);
    }

    function testLinearTotalNegativeSlopePartialClamp() public view {
        // base = 1000, slope = -100: epochs 0..9 give 1000..100, epoch 10 gives 0
        // sum = 10*1000 - 100*(0+1+...+9) = 10000 - 4500 = 5500
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 1000 ether, slope: -100 ether}));
        assertEq(linearEmission.calculateTotal(conf, 10), 5500 ether);
        assertEq(linearEmission.calculateTotal(conf, 11), 5500 ether);
        assertEq(linearEmission.calculateTotal(conf, 1000), 5500 ether);
    }

    function testLinearTotalAllClampedToZero() public view {
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 0, slope: -1 ether}));
        assertEq(linearEmission.calculateTotal(conf, 0), 0);
        assertEq(linearEmission.calculateTotal(conf, 10), 0);
        assertEq(linearEmission.calculateTotal(conf, 1000), 0);
    }

    function testLinearTotalSingleNegativeEpoch() public view {
        // slope steeper than base: only epoch 0 gives anything
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 5 ether, slope: -10 ether}));
        assertEq(linearEmission.calculateTotal(conf, 1), 5 ether);
        assertEq(linearEmission.calculateTotal(conf, 2), 5 ether);
        assertEq(linearEmission.calculateTotal(conf, 1000), 5 ether);
    }

    function testLinearTotalMatchesLoopPositiveSlope(uint256 base, int256 slope, uint256 numEpochs) public view {
        base = bound(base, 0, 1e24);
        slope = bound(slope, 0, 1e18);
        numEpochs = bound(numEpochs, 0, 500);
        bytes memory conf = abi.encode(LinearEmissionConfig({base: base, slope: slope}));
        assertEq(linearEmission.calculateTotal(conf, numEpochs), loopRef.loopTotal(linearEmission, conf, numEpochs));
    }

    function testLinearTotalMatchesLoopNegativeSlope(uint256 base, int256 slope, uint256 numEpochs) public view {
        base = bound(base, 0, 1e24);
        slope = bound(slope, -1e18, 0);
        numEpochs = bound(numEpochs, 0, 500);
        bytes memory conf = abi.encode(LinearEmissionConfig({base: base, slope: slope}));
        assertEq(linearEmission.calculateTotal(conf, numEpochs), loopRef.loopTotal(linearEmission, conf, numEpochs));
    }

    function testLinearTotalMatchesLoopMixedSlope(uint256 base, int256 slope, uint256 numEpochs) public view {
        base = bound(base, 0, 1e24);
        slope = bound(slope, -1e18, 1e18);
        numEpochs = bound(numEpochs, 0, 500);
        bytes memory conf = abi.encode(LinearEmissionConfig({base: base, slope: slope}));
        assertEq(linearEmission.calculateTotal(conf, numEpochs), loopRef.loopTotal(linearEmission, conf, numEpochs));
    }

    function testLinearTotalLargeNumberOfEpochsExact() public view {
        // 100_000 epochs — loop reference still feasible, closed form must be exactly equal
        uint256 numEpochs = 100_000;
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 123 ether, slope: 7 ether}));
        assertEq(linearEmission.calculateTotal(conf, numEpochs), loopRef.loopTotal(linearEmission, conf, numEpochs));

        bytes memory confDecay = abi.encode(LinearEmissionConfig({base: 1e6 ether, slope: -13 ether}));
        assertEq(
            linearEmission.calculateTotal(confDecay, numEpochs), loopRef.loopTotal(linearEmission, confDecay, numEpochs)
        );
    }

    // ============================================================
    // ExponentialEmission
    // ============================================================

    /// @dev tolerance for comparing formula result with the loop sum.
    ///      calculate() truncates on every multiplication (up to 60 wei per epoch, popcount based)
    ///      and truncates the fixed point ratios (~1e-18 relative per squaring),
    ///      so the formula can deviate by up to ~N wei + tiny relative error.
    function _expTolerance(uint256 loopSum, uint256 numEpochs) internal pure returns (uint256) {
        return 60 * numEpochs + 1000 + loopSum / 1e12;
    }

    function testExponentialTotalZeroEpochs() public view {
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 100 ether, numerator: 999, denominator: 1000}));
        assertEq(exponentialEmission.calculateTotal(conf, 0), 0);
    }

    function testExponentialTotalSingleEpoch() public view {
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 100 ether, numerator: 999, denominator: 1000}));
        assertEq(exponentialEmission.calculateTotal(conf, 1), 100 ether);
    }

    function testExponentialTotalRatioOne() public view {
        // r = 1: every epoch gives the same reward, exact answer
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 100 ether, numerator: 777, denominator: 777}));
        assertEq(exponentialEmission.calculateTotal(conf, 100), 10_000 ether);
        assertEq(exponentialEmission.calculateTotal(conf, 1e18), 100 ether * 1e18);
        assertEq(exponentialEmission.calculateTotal(conf, 100), loopRef.loopTotal(exponentialEmission, conf, 100));
    }

    function testExponentialTotalZeroNumerator() public view {
        // numerator = 0: only epoch 0 gives a reward
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 100 ether, numerator: 0, denominator: 1000}));
        assertEq(exponentialEmission.calculateTotal(conf, 1), 100 ether);
        assertEq(exponentialEmission.calculateTotal(conf, 2), 100 ether);
        assertEq(exponentialEmission.calculateTotal(conf, 1e18), 100 ether);
        assertEq(exponentialEmission.calculateTotal(conf, 100), loopRef.loopTotal(exponentialEmission, conf, 100));
    }

    function testExponentialTotalHalvingExactSmallRange() public view {
        // a = 2^40, r = 1/2: all values are exactly representable in the 1e18 fixed point
        // while the squaring exponent stays <= 18 (2^k | 1e18), i.e. epochs < 32
        uint256 a = 2 ** 40;
        bytes memory conf = abi.encode(ExponentialEmissionConfig({initialAmount: a, numerator: 1, denominator: 2}));
        for (uint256 n = 0; n <= 31; n++) {
            // exact geometric sum: sum = a * (2 - 2^(1-n)) = a * (2^(n+1) - 2) / 2^n
            uint256 expected = n == 0 ? 0 : a * ((2 ** (n + 1)) - 2) / (2 ** n);
            assertEq(exponentialEmission.calculateTotal(conf, n), expected, "halving exact");
            assertEq(exponentialEmission.calculateTotal(conf, n), loopRef.loopTotal(exponentialEmission, conf, n));
        }
    }

    function testExponentialTotalHalvingLargeRangeWithinWei() public view {
        uint256 a = 2 ** 40;
        bytes memory conf = abi.encode(ExponentialEmissionConfig({initialAmount: a, numerator: 1, denominator: 2}));
        uint256 n = 100;
        uint256 loop = loopRef.loopTotal(exponentialEmission, conf, n);
        // ideal sum = a * (2 - 2^(1-n)) ~= 2a
        assertEq(exponentialEmission.calculateTotal(conf, n), 2 * a, "halving 100 epochs ~ 2a");
        assertApproxEqAbs(exponentialEmission.calculateTotal(conf, n), loop, _expTolerance(loop, n));
    }

    function testExponentialTotalDecayMatchesLoop() public view {
        ExponentialEmissionConfig[] memory configs = new ExponentialEmissionConfig[](5);
        configs[0] = ExponentialEmissionConfig({initialAmount: 1_000_000, numerator: 999, denominator: 1000});
        configs[1] = ExponentialEmissionConfig({initialAmount: 1e24, numerator: 1, denominator: 3});
        configs[2] = ExponentialEmissionConfig({initialAmount: 999 ether, numerator: 99, denominator: 100});
        configs[3] = ExponentialEmissionConfig({initialAmount: 1 ether, numerator: 1, denominator: 1e12});
        configs[4] = ExponentialEmissionConfig({initialAmount: 123456789, numerator: 123456, denominator: 123457});

        for (uint256 c = 0; c < configs.length; c++) {
            bytes memory conf = abi.encode(configs[c]);
            for (uint256 n = 0; n <= 120; n += 7) {
                uint256 loop = loopRef.loopTotal(exponentialEmission, conf, n);
                assertApproxEqAbs(
                    exponentialEmission.calculateTotal(conf, n), loop, _expTolerance(loop, n), "decay vs loop"
                );
            }
        }
    }

    function testExponentialTotalGrowthMatchesLoop() public view {
        ExponentialEmissionConfig[] memory configs = new ExponentialEmissionConfig[](4);
        configs[0] = ExponentialEmissionConfig({initialAmount: 1e18, numerator: 101, denominator: 100});
        configs[1] = ExponentialEmissionConfig({initialAmount: 1e20, numerator: 1005, denominator: 1000});
        configs[2] = ExponentialEmissionConfig({initialAmount: 1 ether, numerator: 2, denominator: 1});
        configs[3] = ExponentialEmissionConfig({initialAmount: 5e17, numerator: 1000001, denominator: 1000000});

        for (uint256 c = 0; c < configs.length; c++) {
            bytes memory conf = abi.encode(configs[c]);
            for (uint256 n = 0; n <= 60; n += 5) {
                uint256 loop = loopRef.loopTotal(exponentialEmission, conf, n);
                assertApproxEqAbs(
                    exponentialEmission.calculateTotal(conf, n), loop, _expTolerance(loop, n), "growth vs loop"
                );
            }
        }
    }

    function testExponentialTotalGrowthKnownValue() public view {
        // a = 1e18, r = 2: sum over 10 epochs = a * (2^10 - 1) / (2 - 1) = a * 1023
        // every value is exactly representable -> exact answer
        bytes memory conf = abi.encode(ExponentialEmissionConfig({initialAmount: 1e18, numerator: 2, denominator: 1}));
        assertEq(exponentialEmission.calculateTotal(conf, 10), 1023e18);
    }

    function testExponentialTotalDecayHugeNumberOfEpochs() public view {
        // 1e9 epochs — looping is impossible, closed form must be cheap and ~ a / (1 - r) = a * 1000
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 1_000_000, numerator: 999, denominator: 1000}));
        uint256 total = exponentialEmission.calculateTotal(conf, 1_000_000_000);
        // ideal geometric sum = 1e6 * (1 - 0.999^1e9) / 0.001 ~= 1e9
        assertApproxEqRel(total, 1e9, 1e12);

        // partial loop of the first 10k epochs must be less than the full total
        uint256 partialSum = loopRef.loopTotal(exponentialEmission, conf, 10_000);
        assertLt(partialSum, total);
    }

    function testExponentialTotalGrowthHugeNumberOfEpochsRevertsOnOverflow() public {
        // r = 2, a = 1e18: sum for 300 epochs overflows uint256
        bytes memory conf = abi.encode(ExponentialEmissionConfig({initialAmount: 1e18, numerator: 2, denominator: 1}));
        vm.expectRevert();
        exponentialEmission.calculateTotal(conf, 300);
    }

    function testExponentialTotalMonotonicInEpochs() public view {
        ExponentialEmissionConfig[] memory configs = new ExponentialEmissionConfig[](4);
        configs[0] = ExponentialEmissionConfig({initialAmount: 1e21, numerator: 999, denominator: 1000});
        configs[1] = ExponentialEmissionConfig({initialAmount: 1e21, numerator: 1001, denominator: 1000});
        configs[2] = ExponentialEmissionConfig({initialAmount: 1e21, numerator: 1, denominator: 2});
        configs[3] = ExponentialEmissionConfig({initialAmount: 1e21, numerator: 0, denominator: 5});

        for (uint256 c = 0; c < configs.length; c++) {
            bytes memory conf = abi.encode(configs[c]);
            uint256 prev = 0;
            for (uint256 n = 1; n <= 200; n++) {
                uint256 total = exponentialEmission.calculateTotal(conf, n);
                assertGe(total, prev, "total must be non decreasing");
                prev = total;
            }
        }
    }

    function testExponentialTotalFuzzDecay(
        uint256 initialAmount,
        uint256 numerator,
        uint256 denominator,
        uint256 numEpochs
    ) public view {
        denominator = bound(denominator, 1, 1e18);
        numerator = bound(numerator, 0, denominator - 1);
        initialAmount = bound(initialAmount, 0, 1e24);
        numEpochs = bound(numEpochs, 0, 200);

        bytes memory conf = abi.encode(
            ExponentialEmissionConfig({initialAmount: initialAmount, numerator: numerator, denominator: denominator})
        );
        uint256 loop = loopRef.loopTotal(exponentialEmission, conf, numEpochs);
        assertApproxEqAbs(exponentialEmission.calculateTotal(conf, numEpochs), loop, _expTolerance(loop, numEpochs));
    }

    function testExponentialTotalFuzzGrowth(
        uint256 initialAmount,
        uint256 denominator,
        uint256 delta,
        uint256 numEpochs
    ) public view {
        denominator = bound(denominator, 1e12, 1e18);
        delta = bound(delta, 1, denominator / 1000); // growth factor <= 1.001
        initialAmount = bound(initialAmount, 0, 1e24);
        numEpochs = bound(numEpochs, 0, 100);

        uint256 numerator = denominator + delta;
        bytes memory conf = abi.encode(
            ExponentialEmissionConfig({initialAmount: initialAmount, numerator: numerator, denominator: denominator})
        );
        uint256 loop = loopRef.loopTotal(exponentialEmission, conf, numEpochs);
        assertApproxEqAbs(exponentialEmission.calculateTotal(conf, numEpochs), loop, _expTolerance(loop, numEpochs));
    }

    /// @dev calculateTotal must stay O(log N): gas for a huge epoch count is barely more
    ///      than for a small one (binary exponentiation does ~log2(N) iterations)
    function testExponentialTotalGasDoesNotScaleWithEpochs() public {
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 1_000_000, numerator: 999, denominator: 1000}));

        exponentialEmission.calculateTotal(conf, 3);
        Vm.Gas memory small = vm.lastCallGas();

        exponentialEmission.calculateTotal(conf, 1e18);
        Vm.Gas memory huge = vm.lastCallGas();

        // 1e18 epochs = ~60 extra squarings vs 3 epochs, must stay in the same order of magnitude
        assertLt(huge.gasTotalUsed, small.gasTotalUsed * 10);
    }

    /// @dev the function used by the distributor must be reachable through the interface
    function testInterfaceHasCalculateTotal() public view {
        IEmissionFunction emission = exponentialEmission;
        bytes memory conf = abi.encode(ExponentialEmissionConfig({initialAmount: 1000, numerator: 1, denominator: 2}));
        assertEq(emission.calculateTotal(conf, 3), 1750);
    }

    // ============================================================
    // Cross emission sanity checks
    // ============================================================

    /// @dev total(N) - total(N-1) must equal reward of epoch N-1 (within the exponential truncation tolerance)
    function testExponentialTotalConsistentWithCalculate() public view {
        bytes memory conf =
            abi.encode(ExponentialEmissionConfig({initialAmount: 1e21, numerator: 999, denominator: 1000}));
        for (uint256 n = 1; n <= 50; n++) {
            uint256 total = exponentialEmission.calculateTotal(conf, n);
            uint256 diff = total - exponentialEmission.calculateTotal(conf, n - 1);
            uint256 reward = exponentialEmission.calculate(conf, n - 1);
            // calculate() truncates a few wei per multiplication, allow a tiny relative slack on top
            uint256 tolerance = (4 * n * total) / 1e15 + 100;
            assertLe(diff, reward + tolerance, "increment above reward");
            assertGe(diff + tolerance, reward, "increment below reward");
        }
    }

    function testFixedTotalConsistentWithCalculate() public view {
        bytes memory conf = abi.encode(FixedEmissionConfig({amount: 100 ether}));
        for (uint256 n = 1; n <= 50; n++) {
            assertEq(
                fixedEmission.calculateTotal(conf, n) - fixedEmission.calculateTotal(conf, n - 1),
                fixedEmission.calculate(conf, n - 1)
            );
        }
    }

    function testLinearTotalConsistentWithCalculate() public view {
        bytes memory conf = abi.encode(LinearEmissionConfig({base: 1e6 ether, slope: -100 ether}));
        for (uint256 n = 1; n <= 50; n++) {
            assertEq(
                linearEmission.calculateTotal(conf, n) - linearEmission.calculateTotal(conf, n - 1),
                linearEmission.calculate(conf, n - 1)
            );
        }
    }
}
