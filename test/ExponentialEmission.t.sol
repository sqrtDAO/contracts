// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ExponentialEmission, ExponentialEmissionConfig} from "../src/utils/emission-function/ExponentialEmission.sol";
import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

contract ExponentialEmissionTest is Test {
    ExponentialEmission main;
    SimpleExponentialEmission simple;

    bytes conf;

    function setUp() public {
        main = new ExponentialEmission();
        simple = new SimpleExponentialEmission();
        conf = abi.encode(ExponentialEmissionConfig({initialAmount: 1_000_000, numerator: 999, denominator: 1000}));
    }

    function testCloseToSimple() public view {
        for (uint256 i = 0; i < 7; i++) {
            assert(main.calculate(conf, i) - simple.calculate(conf, i) < 5);
        }
    }

    /// these values are calculated with this python function
    /// def rewardOf(epoch):
    ///     ratio = 0.999
    ///     return 1000000 * (ratio ** epoch)
    function testEmissionVsPython() public view {
        uint256 epsilon = 3;
        assert(904792 - main.calculate(conf, 100) < epsilon);
        assert(367695 - main.calculate(conf, 1000) < epsilon);
        assert(135199 - main.calculate(conf, 2000) < epsilon);
        assert(49712 - main.calculate(conf, 3000) < epsilon);
        assert(18279 - main.calculate(conf, 4000) < epsilon);
        assert(6721 - main.calculate(conf, 5000) < epsilon);
        assert(2471 - main.calculate(conf, 6000) < epsilon);
        assert(908 - main.calculate(conf, 7000) < epsilon);
        assert(334 - main.calculate(conf, 8000) < epsilon);
        assert(122 - main.calculate(conf, 9000) < epsilon);
        assert(45 - main.calculate(conf, 10000) < epsilon);
        assert(0 - main.calculate(conf, 100000) < epsilon);
        assert(0 - main.calculate(conf, 1000000) < epsilon);
        assert(0 - main.calculate(conf, 10000000) < epsilon);
        assert(0 - main.calculate(conf, 100000000) < epsilon);
        assert(0 - main.calculate(conf, 1000000000) < epsilon);
    }
}

/// This implementation is problematic because of overflow
/// but we need it so we can test our main implementation in low epoch inputs
contract SimpleExponentialEmission is IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256 _epochNumber) external pure returns (uint256 reward) {
        ExponentialEmissionConfig memory config = abi.decode(_curveConfig, (ExponentialEmissionConfig));

        uint256 factor = config.numerator ** _epochNumber;
        uint256 divisor = config.denominator ** _epochNumber;
        return (config.initialAmount * factor) / divisor;
    }
}
