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

import {ISwapRouterV3} from "../../utils/ISwapRouterv3.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {console} from "forge-std/console.sol";

// example pool extension that takes fees generated for a fee recipient and
// swaps them for a different token
contract UniV3SwapBuyBack is IClankerHookV2PoolExtension, Ownable {
    error LpLockerNotSet();
    error CannotWithdrawInputToken();
    error ClankerNotPairedWithTargetInputToken();
    error InvalidFirstFeeRecipient();
    error InvalidFirstFeeAdmin();
    error InvalidFirstFeePreference();
    error OnlyApprovedHooks();

    event BuyBackRecipientSet(address previousBuyBackRecipient, address newBuyBackRecipient);
    event HookApproved(address hook);
    event SwappedBack(address inputToken, address outputToken, uint256 amountIn, uint256 amountOut);

    // addresses of the fee locker and uni v3 router
    IClanker clankerFactory;
    IClankerFeeLocker feeLocker;
    mapping(address hook => bool approved) public approvedHooks; // addresses of the approved hooks
    ISwapRouterV3 uniV3Router;

    // univ3 pool to swap fee token for
    address public uniV3InputToken;
    address public uniV3OutputToken;
    uint24 public uniV3Fee;

    // address to receive the bought back fees
    address public buyBackRecipient;

    constructor(
        address _owner,
        address _clankerFactory,
        address _feeLocker,
        address _uniV3Router,
        address _uniV3InputToken,
        address _uniV3OutputToken,
        uint24 _uniV3Fee,
        address _buyBackRecipient,
        address[] memory _approvedHooks
    ) Ownable(_owner) {
        clankerFactory = IClanker(_clankerFactory);
        feeLocker = IClankerFeeLocker(_feeLocker);
        uniV3Router = ISwapRouterV3(_uniV3Router);
        uniV3InputToken = _uniV3InputToken;
        uniV3OutputToken = _uniV3OutputToken;
        uniV3Fee = _uniV3Fee;
        buyBackRecipient = _buyBackRecipient;
        for (uint256 i = 0; i < _approvedHooks.length; i++) {
            approvedHooks[_approvedHooks[i]] = true;
        }
    }

    modifier onlyApprovedHooks() {
        if (!approvedHooks[msg.sender]) {
            revert OnlyApprovedHooks();
        }
        _;
    }

    // change the address that receives the bought back fees
    function setBuyBackRecipient(address _buyBackRecipient) external onlyOwner {
        address previousBuyBackRecipient = buyBackRecipient;
        buyBackRecipient = _buyBackRecipient;
        emit BuyBackRecipientSet(previousBuyBackRecipient, buyBackRecipient);
    }

    function approveHook(address _hook) external onlyOwner {
        approvedHooks[_hook] = true;
        emit HookApproved(_hook);
    }

    // initialize the user extension with passed in data, called once per pool
    function initializePreLockerSetup(PoolKey calldata, bool, bytes calldata)
        external
        onlyApprovedHooks
    {}

    function initializePostLockerSetup(
        PoolKey calldata poolKey,
        address lpLocker,
        bool clankerIsToken0
    ) external onlyApprovedHooks {
        // grab the deployed clanker and paired token
        address clanker = clankerIsToken0
            ? Currency.unwrap(poolKey.currency0)
            : Currency.unwrap(poolKey.currency1);
        address pairedToken = clankerIsToken0
            ? Currency.unwrap(poolKey.currency1)
            : Currency.unwrap(poolKey.currency0);

        // check that the token's paired token is the input token
        if (pairedToken != uniV3InputToken) {
            revert ClankerNotPairedWithTargetInputToken();
        }

        // get reward info from the locker
        IClankerLpLocker.TokenRewardInfo memory tokenRewardInfo =
            IClankerLpLocker(lpLocker).tokenRewards(clanker);

        // check that the token reward recipient is this address
        if (tokenRewardInfo.rewardRecipients[0] != address(this)) {
            revert InvalidFirstFeeRecipient();
        }

        // check that the token reward admin is the dead address to prevent the
        // reward recipient from being updated
        if (tokenRewardInfo.rewardAdmins[0] != address(0x000000000000000000000000000000000000dEaD))
        {
            revert InvalidFirstFeeAdmin();
        }

        // check that this fee recipient is only getting the fees in paired token
        if (
            IClankerLpLockerFeeConversion(lpLocker).feePreferences(clanker, 0)
                != IClankerLpLockerFeeConversion.FeeIn.Paired
        ) {
            revert InvalidFirstFeePreference();
        }
    }

    // called after a swap has completed
    function afterSwap(
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bool,
        bytes calldata
    ) external onlyApprovedHooks {
        // claim rewards from the locker
        if (feeLocker.availableFees(address(this), uniV3InputToken) > 0) {
            feeLocker.claim(address(this), uniV3InputToken);
        }

        // if we have no fees to swap, return
        if (IERC20(uniV3InputToken).balanceOf(address(this)) == 0) {
            return;
        }

        // grab amount of token to use for the swap
        uint256 amountIn = IERC20(uniV3InputToken).balanceOf(address(this));

        // approve the swap router for the amount to spend
        SafeERC20.forceApprove(IERC20(uniV3InputToken), address(uniV3Router), amountIn);

        // build the swap params
        ISwapRouterV3.ExactInputSingleParams memory swapBackParams = ISwapRouterV3
            .ExactInputSingleParams({
            tokenIn: uniV3InputToken,
            tokenOut: uniV3OutputToken,
            fee: uniV3Fee,
            recipient: buyBackRecipient,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // swap the fees for the output token
        uint256 amountOut = uniV3Router.exactInputSingle(swapBackParams);

        // record the amount swapped
        emit SwappedBack(uniV3InputToken, uniV3OutputToken, amountIn, amountOut);
    }

    // Withdraw ETH from the contract
    function withdrawETH(address recipient) public onlyOwner {
        payable(recipient).transfer(address(this).balance);
    }

    // Withdraw ERC20 tokens from the contract
    function withdrawERC20(address token, address recipient) public onlyOwner {
        IERC20 token_ = IERC20(token);
        SafeERC20.safeTransfer(token_, recipient, token_.balanceOf(address(this)));
    }

    // implements the IClankerHookV2PoolExtension interface
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IClankerHookV2PoolExtension).interfaceId;
    }
}
