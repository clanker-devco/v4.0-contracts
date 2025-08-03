// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClankerHookV2} from "./ClankerHookV2.sol";
import {IClankerHookStaticFee} from "./interfaces/IClankerHookStaticFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract ClankerHookStaticFeeV2 is ClankerHookV2, IClankerHookStaticFee {
    mapping(PoolId => uint24) public clankerFee;
    mapping(PoolId => uint24) public pairedFee;

    constructor(address _poolManager, address _factory, address _weth)
        ClankerHookV2(_poolManager, _factory, _weth)
    {}

    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal override {
        PoolStaticConfigVars memory _poolConfigVars = abi.decode(feeData, (PoolStaticConfigVars));

        if (_poolConfigVars.clankerFee > MAX_LP_FEE) {
            revert ClankerFeeTooHigh();
        }

        if (_poolConfigVars.pairedFee > MAX_LP_FEE) {
            revert PairedFeeTooHigh();
        }

        clankerFee[poolKey.toId()] = _poolConfigVars.clankerFee;
        pairedFee[poolKey.toId()] = _poolConfigVars.pairedFee;

        emit PoolInitialized(poolKey.toId(), _poolConfigVars.clankerFee, _poolConfigVars.pairedFee);
    }

    // set the LP fee according to the clanker/paired fee configuration
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        override
    {
        uint24 fee = swapParams.zeroForOne != clankerIsToken0[poolKey.toId()]
            ? pairedFee[poolKey.toId()]
            : clankerFee[poolKey.toId()];

        _setProtocolFee(fee);
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
    }
}
