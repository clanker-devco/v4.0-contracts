// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IClankerSniperAuctionV0} from "../ClankerSniperAuctionV0.sol";

/*
 .--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--. 
/ .. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \
\ \/\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ \/ /
 \/ /`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'\/ / 
 / /\  ````````````````````````````````````````````````````````````````````````````````````  / /\ 
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````::::::::``:::````````````:::`````::::````:::`:::````:::`::::::::::`:::::::::` \ \/ /
 \/ /  `````:+:````:+:`:+:``````````:+:`:+:```:+:+:```:+:`:+:```:+:``:+:````````:+:````:+:`  \/ / 
 / /\  ````+:+````````+:+`````````+:+```+:+``:+:+:+``+:+`+:+``+:+```+:+````````+:+````+:+``  / /\ 
/ /\ \ ```+#+````````+#+````````+#++:++#++:`+#+`+:+`+#+`+#++:++````+#++:++#```+#++:++#:```` / /\ \
\ \/ / ``+#+````````+#+````````+#+`````+#+`+#+``+#+#+#`+#+``+#+```+#+````````+#+````+#+```` \ \/ /
 \/ /  `#+#````#+#`#+#````````#+#`````#+#`#+#```#+#+#`#+#```#+#``#+#````````#+#````#+#`````  \/ / 
 / /\  `########``##########`###`````###`###````####`###````###`##########`###````###``````  / /\ 
/ /\ \ ```````````````````````````````````````````````````````````````````````````````````` / /\ \
\ \/ / ```````````````````````````````````````````````````````````````````````````````````` \ \/ /
 \/ /  ````````````````````````````````````````````````````````````````````````````````````  \/ / 
 / /\.--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--..--./ /\ 
/ /\ \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \.. \/\ \
\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `'\ `' /
 `--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--'`--' 
*/

// shared util for snipers to bid in ClankerSniperAuctionV0 auctions
contract ClankerSniperUtilV0 is ReentrancyGuard {
    event AuctionSuccessful(
        PoolId indexed poolId,
        uint256 indexed round,
        address indexed payee,
        uint256 paymentAmount,
        uint256 amountIn,
        uint256 amountOut
    );

    error InvalidBidAmount();
    error InvalidRound();
    error InvalidBlock();
    error AuctionDidNotAdvance();

    IClankerSniperAuctionV0 immutable clankerSniperAuction;
    IUniversalRouter immutable universalRouter;
    IPermit2 immutable permit2;
    address immutable weth;

    constructor(
        address _clankerSniperAuction,
        address _universalRouter,
        address _permit2,
        address _weth
    ) {
        clankerSniperAuction = IClankerSniperAuctionV0(_clankerSniperAuction);
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);
        weth = _weth;
    }

    // helper function to calculate needed tx gas price for a target bid amount
    function getTxGasPriceForBidAmount(uint256 auctionGasPeg, uint256 desiredBidAmount)
        external
        view
        returns (uint256 txGasPrice)
    {
        // bidding amount must be in units of gas difference
        if (desiredBidAmount % clankerSniperAuction.PAYMENT_PER_GAS_UNIT() != 0) {
            revert InvalidBidAmount();
        }

        // calculate the gas price for the bid amount
        txGasPrice =
            auctionGasPeg + (desiredBidAmount / clankerSniperAuction.PAYMENT_PER_GAS_UNIT());
    }

    // basic util function to show snipers how to bid in the auction
    function bidInAuction(IV4Router.ExactInputSingleParams memory swapParams, uint256 round)
        external
        payable
        nonReentrant
    {
        PoolId poolId = swapParams.poolKey.toId();

        // check that the intended round is being bid in
        if (
            round != clankerSniperAuction.round(poolId) || round > clankerSniperAuction.MAX_ROUNDS()
        ) {
            revert InvalidRound();
        }

        // check that the correct block is being bid in
        if (block.number != clankerSniperAuction.nextAuctionBlock(poolId)) {
            revert InvalidBlock();
        }

        // convert payment msg.value to weth
        IWETH9(weth).deposit{value: msg.value}();

        // approve the sniper auction to spend the weth
        IERC20(weth).approve(address(clankerSniperAuction), msg.value);

        // token in and token out
        (address tokenIn, address tokenOut) = swapParams.zeroForOne
            ? (
                Currency.unwrap(swapParams.poolKey.currency0),
                Currency.unwrap(swapParams.poolKey.currency1)
            )
            : (
                Currency.unwrap(swapParams.poolKey.currency1),
                Currency.unwrap(swapParams.poolKey.currency0)
            );

        // pull in token in
        SafeERC20.safeTransferFrom(IERC20(tokenIn), msg.sender, address(this), swapParams.amountIn);

        // encode the hook swap info with this as the payee address
        swapParams.hookData = abi.encode(address(this));

        // perform the swap, will trigger the auction
        _univ4Swap(swapParams);

        // transfer the output tokens to the msg.sender
        uint256 tokenOutBalance = IERC20(tokenOut).balanceOf(address(this));
        SafeERC20.safeTransfer(IERC20(tokenOut), msg.sender, tokenOutBalance);

        // ensure that the auction round advanced
        if (round + 1 != clankerSniperAuction.round(poolId)) {
            revert AuctionDidNotAdvance();
        }

        emit AuctionSuccessful(
            poolId, round, msg.sender, msg.value, swapParams.amountIn, tokenOutBalance
        );
    }

    // helper function to perform a swap on univ4
    function _univ4Swap(IV4Router.ExactInputSingleParams memory swapParams) internal {
        // initiate a swap command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);

        // token in and token out
        (address tokenIn, address tokenOut) = swapParams.zeroForOne
            ? (
                Currency.unwrap(swapParams.poolKey.currency0),
                Currency.unwrap(swapParams.poolKey.currency1)
            )
            : (
                Currency.unwrap(swapParams.poolKey.currency1),
                Currency.unwrap(swapParams.poolKey.currency0)
            );

        // First parameter: SWAP_EXACT_IN_SINGLE
        params[0] = abi.encode(swapParams);

        // Second parameter: SETTLE_ALL
        params[1] = abi.encode(tokenIn, swapParams.amountIn);

        // Third parameter: TAKE_ALL
        params[2] = abi.encode(tokenOut, 1);

        // Combine actions and params into inputs
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        // approve the paired token to be spent by the router
        IERC20(tokenIn).approve(address(permit2), swapParams.amountIn);
        permit2.approve(
            tokenIn, address(universalRouter), swapParams.amountIn, uint48(block.timestamp)
        );

        // Execute the swap
        universalRouter.execute(commands, inputs, block.timestamp);
    }
}