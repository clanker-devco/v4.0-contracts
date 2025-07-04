// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IClankerFeeLocker} from "./interfaces/IClankerFeeLocker.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ClankerFeeLocker is IClankerFeeLocker, ReentrancyGuard, Ownable {
    mapping(address feeOwner => mapping(address token => uint256 balance)) public feesToClaim;
    mapping(address depositor => bool isAllowed) public allowedDepositors;

    constructor(address owner_) Ownable(owner_) {}

    function addDepositor(address depositor) external onlyOwner {
        allowedDepositors[depositor] = true;
        emit AddDepositor(depositor);
    }

    function storeFees(address feeOwner, address token, uint256 amount) external nonReentrant {
        if (!allowedDepositors[msg.sender]) revert Unauthorized();

        // use balance deltas to support fee on transfer and weird tokens
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 receivedAmount = balanceAfter - balanceBefore;

        feesToClaim[feeOwner][token] += receivedAmount;
        emit StoreTokens(msg.sender, feeOwner, token, feesToClaim[feeOwner][token], amount);
    }

    // helper function to check available fees
    function availableFees(address feeOwner, address token) external view returns (uint256) {
        return feesToClaim[feeOwner][token];
    }

    // claim fees on behalf of a feeOwner
    function claim(address feeOwner, address token) external nonReentrant {
        uint256 balance = feesToClaim[feeOwner][token];
        if (balance == 0) revert NoFeesToClaim();

        // debit account
        feesToClaim[feeOwner][token] = 0;

        // transfer funds
        SafeERC20.safeTransfer(IERC20(token), feeOwner, balance);

        emit ClaimTokens(feeOwner, token, balance);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IClankerFeeLocker).interfaceId;
    }
}
