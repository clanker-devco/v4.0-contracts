// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClankerMevModule} from "../../interfaces/IClankerMevModule.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IClankerSniperAuctionV0 is IClankerMevModule {
    error PoolAlreadyInitialized();
    error GasSignalNegative();
    error InvalidPayment();
    error NotAuctionBlock();

    event AuctionInitialized(
        PoolId indexed poolId, uint256 gasPeg, uint256 indexed blockNumber, uint256 round
    );
    event AuctionWon(
        PoolId indexed poolId, address indexed payee, uint256 paymentAmount, uint256 round
    );
    event AuctionReset(PoolId indexed poolId, uint256 round);
    event AuctionExpired(PoolId indexed poolId, uint256 round);
    event AuctionEnded(PoolId indexed poolId);
    event AuctionRewardsTransferred(
        PoolId indexed poolId, uint256 lpPayment, uint256 factoryPayment
    );

    function gasPeg(PoolId poolId) external view returns (uint256);
    function round(PoolId poolId) external view returns (uint256);
    function nextAuctionBlock(PoolId poolId) external view returns (uint256);

    function PAYMENT_PER_GAS_UNIT() external view returns (uint256);
    function MAX_ROUNDS() external view returns (uint256);
    function BLOCKS_BETWEEN_AUCTION() external view returns (uint256);
}