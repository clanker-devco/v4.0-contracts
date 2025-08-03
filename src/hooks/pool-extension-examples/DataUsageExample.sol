// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClanker} from "../../interfaces/IClanker.sol";
import {IClankerFeeLocker} from "../../interfaces/IClankerFeeLocker.sol";
import {IClankerLpLocker} from "../../interfaces/IClankerLpLocker.sol";
import {IClankerLpLockerFeeConversion} from
    "../../lp-lockers/interfaces/IClankerLpLockerFeeConversion.sol";
import {IClankerHookV2} from "../interfaces/IClankerHookV2.sol";

import {IClankerHookV2PoolExtension} from "../interfaces/IClankerHookV2PoolExtension.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {console} from "forge-std/console.sol";

// example pool extension that accesses passed in data in the setup and swap phases
contract DataUsageExample is IClankerHookV2PoolExtension {
    error InvalidFoo();

    uint256 constant REQUIRED_FOO = 42;
    mapping(
        address user => mapping(PoolId poolId => mapping(address tokenSpent => uint128 amountSpent))
    ) public amountSpent;

    struct PoolInitializationData {
        uint256 foo;
    }

    struct PoolSwapData {
        address user;
    }

    // initialized pool keys
    mapping(PoolId => bool) public initializedPoolKeys;

    modifier onlyHook(PoolKey calldata poolKey) {
        if (msg.sender != address(poolKey.hooks)) {
            revert OnlyHook();
        }
        _;
    }

    function initializePreLockerSetup(
        PoolKey calldata poolKey,
        bool clankerIsToken0,
        bytes calldata poolExtensionData
    ) external onlyHook(poolKey) {
        // check that the foo is the required foo
        //
        // could revent on other conditions too, e.g. the passed in data is a signature
        // from a particular address over the pool key and the tx.origin
        if (abi.decode(poolExtensionData, (PoolInitializationData)).foo != REQUIRED_FOO) {
            revert InvalidFoo();
        }

        // set the pool key as initialized
        initializedPoolKeys[poolKey.toId()] = true;
    }

    function initializePostLockerSetup(PoolKey calldata poolKey, address lpLocker, bool)
        external
        onlyHook(poolKey)
    {}

    // called after a swap has completed
    function afterSwap(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bool clankerIsToken0,
        bytes calldata swapData
    ) external onlyHook(poolKey) {
        // attempt to decode the swap data if present
        //
        // note: if the swap data is in the wrong shape, this will revert but the hook will
        // handle it gracefully and continue the swap
        PoolSwapData memory poolSwapData = abi.decode(swapData, (PoolSwapData));

        if (poolSwapData.user == address(0)) {
            return;
        }

        // record the amount of token spent by the user
        // note for the delta: the amount owed to the caller (positive) or owed to the pool (negative)
        if (delta.amount1() < 0) {
            console.log("---");
            console.log("delta1", delta.amount1());
            console.log("poolKey.currency1 unwrapped", Currency.unwrap(poolKey.currency1));
            console.log("amount spent", swapParams.amountSpecified);
            amountSpent[poolSwapData.user][poolKey.toId()][Currency.unwrap(poolKey.currency1)] +=
                uint128(-delta.amount1());
        } else {
            console.log("---");
            console.log("delta0", delta.amount0());
            console.log("poolKey.currency0 unwrapped", Currency.unwrap(poolKey.currency0));
            console.log("amount spent", swapParams.amountSpecified);
            amountSpent[poolSwapData.user][poolKey.toId()][Currency.unwrap(poolKey.currency0)] +=
                uint128(-delta.amount0());
        }
    }

    // implements the IClankerHookV2PoolExtension interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IClankerHookV2PoolExtension).interfaceId;
    }
}
