// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title IRwaTwapSource — minimal view of RWAGateHook's TWAP oracle
/// @notice Local interface so the 0.8.30 compilation unit (swap-vm pins solc) never imports
///         Uniswap v4 types (v4-core pins solc 0.8.26). `poolId` is v4's PoolId (a bytes32).
interface IRwaTwapSource {
    /// @return rate1e18 Time-weighted USDC-per-RWA rate, 1e18 scale, decimals-normalized.
    function twapRate(bytes32 poolId, uint32 window) external view returns (uint256 rate1e18);
}
