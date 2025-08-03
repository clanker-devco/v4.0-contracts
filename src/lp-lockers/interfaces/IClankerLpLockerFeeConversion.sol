// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClankerLpLocker} from "../../interfaces/IClankerLpLocker.sol";
import {IClankerLpLockerMultiple} from "./IClankerLpLockerMultiple.sol";

interface IClankerLpLockerFeeConversion is IClankerLpLockerMultiple {
    enum FeeIn {
        Both,
        Paired,
        Clanker
    }

    struct LpFeeConversionInfo {
        FeeIn[] feePreference;
    }

    event FeePreferenceUpdated(
        address indexed token,
        uint256 indexed rewardIndex,
        FeeIn oldFeePreference,
        FeeIn indexed newFeePreference
    );

    event FeesSwapped(
        address indexed token,
        address indexed rewardToken,
        uint256 amountSwapped,
        address indexed swappedToken,
        uint256 amountOut
    );

    event InitialFeePreferences(address indexed token, FeeIn[] feePreference);

    function feePreferences(address token, uint256 index) external view returns (FeeIn);
}
