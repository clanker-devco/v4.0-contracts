// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ClankerToken} from "../ClankerToken.sol";

import {IClanker} from "../interfaces/IClanker.sol";

import {IClankerLpLocker} from "../interfaces/IClankerLpLocker.sol";
import {IClankerMevModule} from "../interfaces/IClankerMevModule.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {IClankerHookV2PoolExtension} from "./interfaces/IClankerHookV2PoolExtension.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IClankerHook} from "../interfaces/IClankerHook.sol";
import {IClankerHookV2} from "./interfaces/IClankerHookV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BalanceDelta, add, sub, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {console} from "forge-std/console.sol";

abstract contract ClankerHookV2 is BaseHook, IClankerHookV2 {
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using StateLibrary for *;

    uint24 public constant MAX_LP_FEE = 300_000; // LP fee capped at 30%
    uint256 public constant PROTOCOL_FEE_NUMERATOR = 200_000; // 20% of the imposed LP fee
    int128 public constant FEE_DENOMINATOR = 1_000_000; // Uniswap 100% fee

    uint24 public protocolFee;

    address public immutable factory;
    address public immutable weth;

    mapping(PoolId => bool) public clankerIsToken0;
    mapping(PoolId => address) public locker;

    // mev module pool variables
    uint256 public constant MAX_MEV_MODULE_DELAY = 20 minutes;
    mapping(PoolId => address) public mevModule;
    mapping(PoolId => bool) public mevModuleEnabled;
    mapping(PoolId => uint256) public poolCreationTimestamp;
    mapping(PoolId => address) public poolExtension;

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    constructor(address _poolManager, address _factory, address _weth)
        BaseHook(IPoolManager(_poolManager))
    {
        factory = _factory;
        weth = _weth;
    }

    // function to for inheriting hooks to set fees in _beforeSwap hook
    function _setFee(PoolKey calldata poolKey, IPoolManager.SwapParams calldata swapParams)
        internal
        virtual
    {
        return;
    }

    // function to set the protocol fee to 20% of the lp fee
    function _setProtocolFee(uint24 lpFee) internal {
        protocolFee = uint24(uint256(lpFee) * PROTOCOL_FEE_NUMERATOR / uint128(FEE_DENOMINATOR));
    }

    // function to for inheriting hooks to set process data in during initialization flow
    function _initializeFeeData(PoolKey memory poolKey, bytes memory feeData) internal virtual {
        return;
    }

    function _initializePoolExtensionData(
        PoolKey memory poolKey,
        address _poolExtension,
        bytes memory poolExtensionData
    ) internal virtual {
        if (_poolExtension != address(0)) {
            IClankerHookV2PoolExtension(_poolExtension).initializePreLockerSetup(
                poolKey, clankerIsToken0[poolKey.toId()], poolExtensionData
            );
            poolExtension[poolKey.toId()] = _poolExtension;
        }
        return;
    }

    // function for the factory to initialize a pool
    function initializePool(
        address clanker,
        address pairedToken,
        int24 tickIfToken0IsClanker,
        int24 tickSpacing,
        address _locker,
        address _mevModule,
        bytes calldata poolData
    ) public onlyFactory returns (PoolKey memory) {
        // initialize the pool
        PoolKey memory poolKey =
            _initializePool(clanker, pairedToken, tickIfToken0IsClanker, tickSpacing, poolData);

        // set the locker config
        locker[poolKey.toId()] = _locker;

        // set the mev module
        mevModule[poolKey.toId()] = _mevModule;

        emit PoolCreatedFactory({
            pairedToken: pairedToken,
            clanker: clanker,
            poolId: poolKey.toId(),
            tickIfToken0IsClanker: tickIfToken0IsClanker,
            tickSpacing: tickSpacing,
            locker: _locker,
            mevModule: _mevModule
        });

        return poolKey;
    }

    // function to let anyone initialize a pool
    //
    // this is allow tokens not created by the factory to be used with this hook
    //
    // note: these pools do not have lp locker auto-claim or mev module functionality
    function initializePoolOpen(
        address clanker,
        address pairedToken,
        int24 tickIfToken0IsClanker,
        int24 tickSpacing,
        bytes calldata poolData
    ) public returns (PoolKey memory) {
        // if able, we prefer that weth is not the clanker as our hook fee will only
        // collect fees on the paired token
        if (clanker == weth) {
            revert WethCannotBeClanker();
        }

        PoolKey memory poolKey =
            _initializePool(clanker, pairedToken, tickIfToken0IsClanker, tickSpacing, poolData);

        emit PoolCreatedOpen(
            pairedToken, clanker, poolKey.toId(), tickIfToken0IsClanker, tickSpacing
        );

        return poolKey;
    }

    // common actions for initializing a pool
    function _initializePool(
        address clanker,
        address pairedToken,
        int24 tickIfToken0IsClanker,
        int24 tickSpacing,
        bytes calldata poolData
    ) internal virtual returns (PoolKey memory) {
        // ensure that the pool is not an ETH pool
        if (pairedToken == address(0) || clanker == address(0)) {
            revert ETHPoolNotAllowed();
        }

        // determine if clanker is token0
        bool token0IsClanker = clanker < pairedToken;

        // create the pool key
        PoolKey memory _poolKey = PoolKey({
            currency0: Currency.wrap(token0IsClanker ? clanker : pairedToken),
            currency1: Currency.wrap(token0IsClanker ? pairedToken : clanker),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        // Set the storage helpers
        clankerIsToken0[_poolKey.toId()] = token0IsClanker;

        // initialize the pool
        int24 startingTick = token0IsClanker ? tickIfToken0IsClanker : -tickIfToken0IsClanker;
        uint160 initialPrice = startingTick.getSqrtPriceAtTick();
        poolManager.initialize(_poolKey, initialPrice);

        // set the pool creation timestamp
        poolCreationTimestamp[_poolKey.toId()] = block.timestamp;

        // decode the pool data into user extension data and pool data
        PoolInitializationData memory poolInitializationData =
            abi.decode(poolData, (PoolInitializationData));

        // initialize fee data
        _initializeFeeData(_poolKey, poolInitializationData.feeData);

        // initialize pool extension data
        _initializePoolExtensionData(
            _poolKey, poolInitializationData.extension, poolInitializationData.extensionData
        );

        return _poolKey;
    }

    // enable the mev module once the pool's deployment is complete
    //
    // note: this is done separate from the initializePool to allow for
    // extensions to take pool actions
    function initializeMevModule(PoolKey calldata poolKey, bytes calldata mevModuleData)
        external
        onlyFactory
    {
        // initialize the mev module
        IClankerMevModule(mevModule[poolKey.toId()]).initialize(poolKey, mevModuleData);

        // give pool extension, if it exists, chance to check other configured settings
        if (poolExtension[poolKey.toId()] != address(0)) {
            IClankerHookV2PoolExtension(poolExtension[poolKey.toId()]).initializePostLockerSetup(
                poolKey, locker[poolKey.toId()], clankerIsToken0[poolKey.toId()]
            );
        }

        // enable the mev module
        mevModuleEnabled[poolKey.toId()] = true;
    }

    // returns true if the mev module is enabled and not expired
    function mevModuleOperational(PoolId poolId) public view returns (bool) {
        return mevModuleEnabled[poolId]
            && block.timestamp < poolCreationTimestamp[poolId] + MAX_MEV_MODULE_DELAY;
    }

    // function to allow the mev module to change the fee for a swap
    function mevModuleSetFee(PoolKey calldata poolKey, uint24 fee) external {
        // only the assigned mev module for a poolkey can update the fee
        if (mevModule[poolKey.toId()] != msg.sender) {
            revert Unauthorized();
        }

        // skip if the mev module is not operational
        if (!mevModuleOperational(poolKey.toId())) {
            return;
        }

        // check to see if the fee is higher than the currently set LP fee,
        // we only want to update if it is higher than the pool's normal fee behavior
        (,,, uint24 currentLpFee) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        if (fee <= currentLpFee) {
            return;
        }

        // update the fee for the swap
        IPoolManager(poolManager).updateDynamicLPFee(poolKey, fee);
        _setProtocolFee(fee);

        emit MevModuleSetFee(poolKey.toId(), fee);
    }

    function _runMevModule(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal {
        if (mevModuleOperational(poolKey.toId())) {
            // decode the swap data for the pool extension
            PoolSwapData memory poolSwapData;
            if (swapData.length > 0) {
                poolSwapData = abi.decode(swapData, (PoolSwapData));
            } else {
                poolSwapData = PoolSwapData({
                    mevModuleSwapData: new bytes(0),
                    poolExtensionSwapData: new bytes(0)
                });
            }

            // if the mev module is enabled  call it
            bool disableMevModule = IClankerMevModule(mevModule[poolKey.toId()]).beforeSwap(
                poolKey, swapParams, clankerIsToken0[poolKey.toId()], poolSwapData.mevModuleSwapData
            );

            // disable the mevModule if the module requests it
            if (disableMevModule) {
                mevModuleEnabled[poolKey.toId()] = false;
                emit MevModuleDisabled(poolKey.toId());
            }
        }
    }

    function _runPoolExtension(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal {
        console.log("poolExtension");
        console.log(poolExtension[poolKey.toId()]);

        if (poolExtension[poolKey.toId()] != address(0)) {
            // decode the swap data for the mev module
            PoolSwapData memory poolSwapData;
            if (swapData.length > 0) {
                poolSwapData = abi.decode(swapData, (PoolSwapData));
            } else {
                poolSwapData = PoolSwapData({
                    mevModuleSwapData: new bytes(0),
                    poolExtensionSwapData: new bytes(0)
                });
            }

            console.log("poolExtensionSwapData");

            try this._runPoolExtensionHelper(
                poolKey, swapParams, delta, poolSwapData.poolExtensionSwapData
            ) {
                emit PoolExtensionSuccess(poolKey.toId());
            } catch {
                emit PoolExtensionFailed(poolKey.toId(), swapParams);
            }
        }
    }

    function _runPoolExtensionHelper(
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) external {
        if (msg.sender != address(this)) {
            revert OnlyThis();
        }

        IClankerHookV2PoolExtension(poolExtension[poolKey.toId()]).afterSwap(
            poolKey, swapParams, delta, clankerIsToken0[poolKey.toId()], swapData
        );
    }

    function _lpLockerFeeClaim(PoolKey calldata poolKey) internal {
        // if this wasn't initialized to claim fees, skip the claim
        if (locker[poolKey.toId()] == address(0)) {
            return;
        }

        // determine the token
        address token = clankerIsToken0[poolKey.toId()]
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);

        // trigger the fee claim
        IClankerLpLocker(locker[poolKey.toId()]).collectRewardsWithoutUnlock(token);
    }

    function _hookFeeClaim(PoolKey calldata poolKey) internal {
        // determine the fee token
        Currency feeCurrency =
            clankerIsToken0[poolKey.toId()] ? poolKey.currency1 : poolKey.currency0;

        // get the fees stored from the previous swap in the pool manager
        uint256 fee = poolManager.balanceOf(address(this), feeCurrency.toId());

        if (fee == 0) {
            return;
        }

        // burn the fee
        poolManager.burn(address(this), feeCurrency.toId(), fee);

        // take the fee
        poolManager.take(feeCurrency, factory, fee);

        emit ClaimProtocolFees(Currency.unwrap(feeCurrency), fee);
    }

    function _beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata swapData
    ) internal virtual override returns (bytes4, BeforeSwapDelta delta, uint24) {
        // set the fee for this swap
        _setFee(poolKey, swapParams);

        // trigger hook fee claim
        _hookFeeClaim(poolKey);

        // trigger the LP locker fee claim
        _lpLockerFeeClaim(poolKey);

        // run the mev module, can update the fee for the swap
        _runMevModule(poolKey, swapParams, swapData);

        // variables to determine how to collect protocol fee
        bool token0IsClanker = clankerIsToken0[poolKey.toId()];
        bool swappingForClanker = swapParams.zeroForOne != token0IsClanker;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount paired in, unspecified amount clanker out
        // want to: keep amountIn the same, take fee on amountIn
        // how: we modulate the specified amount being swapped DOWN, and
        // transfer the difference into the hook's account before making the swap
        if (isExactInput && swappingForClanker) {
            // since we're taking the protocol fee before the LP swap, we want to
            // take a slightly smaller amount to keep the taken LP/protocol fee at the 20% ratio,
            // this also helps us match the ExactOutput swappingForClanker scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 + protocolFee);
            int128 fee = int128(swapParams.amountSpecified * -int128(scaledProtocolFee) / 1e18);

            delta = toBeforeSwapDelta(fee, 0);
            poolManager.mint(
                address(this),
                token0IsClanker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        // case: specified amount paired out, unspecified amount clanker in
        // want to: increase amountOut by fee and take it
        // how: we modulate the specified amount out UP, and transfer it
        // into the hook's account
        if (!isExactInput && !swappingForClanker) {
            // we increase the protocol fee here because we want to better match
            // the ExactOutput !swappingForClanker scenario
            uint128 scaledProtocolFee = uint128(protocolFee) * 1e18 / (1_000_000 - protocolFee);
            int128 fee = int128(swapParams.amountSpecified * int128(scaledProtocolFee) / 1e18);
            delta = toBeforeSwapDelta(fee, 0);

            poolManager.mint(
                address(this),
                token0IsClanker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(fee))
            );
        }

        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata swapData
    ) internal override returns (bytes4, int128 unspecifiedDelta) {
        // variables to determine how to collect protocol fee
        bool token0IsClanker = clankerIsToken0[poolKey.toId()];
        bool swappingForClanker = swapParams.zeroForOne != token0IsClanker;
        bool isExactInput = swapParams.amountSpecified < 0;

        // case: specified amount clanker in, unspecified amount paired out
        // want to: take fee on amount out
        // how: the change in unspecified delta is debited to the swaps account post swap,
        // in this case the amount out given to the swapper is decreased
        if (isExactInput && !swappingForClanker) {
            // grab non-clanker amount out
            int128 amountOut = token0IsClanker ? delta.amount1() : delta.amount0();
            // take fee from it
            unspecifiedDelta = amountOut * int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsClanker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );

            // subtract the protocol fee from the positive delta to account for the protocol fee
            // (positive for the swapper means amount owed to the swapper)
            if (delta.amount0() > 0) {
                delta = sub(delta, toBalanceDelta(unspecifiedDelta, 0));
            } else {
                delta = sub(delta, toBalanceDelta(0, unspecifiedDelta));
            }
        }

        // case: specified amount clanker out, unspecified amount paired in
        // want to: take fee on amount in
        // how: the change in unspecified delta is debited to the swapper's account post swap,
        // in this case the amount taken from the swapper's account is increased
        if (!isExactInput && swappingForClanker) {
            // grab non-clanker amount in
            int128 amountIn = token0IsClanker ? delta.amount1() : delta.amount0();
            // take fee from amount int
            unspecifiedDelta = amountIn * -int24(protocolFee) / FEE_DENOMINATOR;
            poolManager.mint(
                address(this),
                token0IsClanker ? poolKey.currency1.toId() : poolKey.currency0.toId(),
                uint256(int256(unspecifiedDelta))
            );

            // subtract the protocol fee from the negative delta to account for the protocol fee
            // (negative for the swapper means amount owed to the pool)
            if (delta.amount0() < 0) {
                delta = sub(delta, toBalanceDelta(unspecifiedDelta, 0));
            } else {
                delta = sub(delta, toBalanceDelta(0, unspecifiedDelta));
            }
        }

        // modify deltas to account for when the protocol fee is taken in beforeSwap,
        // the actual user delta is the amount specified in the swap params
        if (isExactInput && swappingForClanker) {
            // need to modify the paired delta to be the amount specified in the swap params
            if (clankerIsToken0[poolKey.toId()]) {
                delta = toBalanceDelta(delta.amount0(), int128(swapParams.amountSpecified));
            } else {
                delta = toBalanceDelta(int128(swapParams.amountSpecified), delta.amount1());
            }
        } else if (!isExactInput && !swappingForClanker) {
            // TODO: test is if this is correct ...
            // need to modify the clanker delta to be the amount specified in the swap params
            if (clankerIsToken0[poolKey.toId()]) {
                delta = toBalanceDelta(int128(swapParams.amountSpecified), delta.amount1());
            } else {
                delta = toBalanceDelta(delta.amount0(), int128(swapParams.amountSpecified));
            }
        }

        // run the pool extension
        _runPoolExtension(poolKey, swapParams, delta, swapData);

        return (BaseHook.afterSwap.selector, unspecifiedDelta);
    }

    // prevent initializations that don't start via our initializePool functions
    function _beforeInitialize(address, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert UnsupportedInitializePath();
    }

    // prevent liquidity adds during mev module operation
    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (mevModuleOperational(poolKey.toId())) {
            revert MevModuleEnabled();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IClankerHook).interfaceId
            || interfaceId == type(IClankerHookV2).interfaceId;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
