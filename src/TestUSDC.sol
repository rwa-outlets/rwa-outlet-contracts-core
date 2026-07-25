// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestUSDC — 6-decimals mintable stablecoin (Base Sepolia demo only)
/// @notice Mainnet-fork demos use real USDC; this exists for public-testnet deploys
///         (docs/03-contracts.md §2.4).
contract TestUSDC is ERC20, Ownable {
    constructor() ERC20("Test USD Coin", "USDC") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
