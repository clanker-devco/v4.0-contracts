// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IClankerHook} from "../../interfaces/IClankerHook.sol";

interface IClankerHookV2 is IClankerHook {
    error OnlyThis();
    error MevModuleNotOperational();
    error Unauthorized();

    event PoolExtensionSuccess(PoolId poolId);
    event PoolExtensionFailed(PoolId poolId, IPoolManager.SwapParams swapParams);
    event MevModuleSetFee(PoolId poolId, uint24 fee);

    struct PoolInitializationData {
        address extension;
        bytes extensionData;
        bytes feeData;
    }

    struct PoolSwapData {
        bytes mevModuleSwapData;
        bytes poolExtensionSwapData;
    }

    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external;

    function mevModuleEnabled(PoolId poolId) external view returns (bool);
    function poolCreationTimestamp(PoolId poolId) external view returns (uint256);
    function MAX_MEV_MODULE_DELAY() external view returns (uint256);
    function MAX_LP_FEE() external view returns (uint24);
}
