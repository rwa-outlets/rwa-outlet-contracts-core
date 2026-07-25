// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @title IV4Venue — minimal view of the Uniswap v4 execution venue
/// @notice Local interface so the 0.8.30 compilation unit (swap-vm pins solc) never imports
///         Uniswap v4 types (v4-core pins solc 0.8.26). One venue serves every listed asset;
///         each registered pool pairs the asset with USDC and carries the RWAGateHook.
interface IV4Venue {
    /// @return poolId v4 PoolId of the asset's RWA/USDC pool (zero when not registered).
    function poolIdOf(address asset) external view returns (bytes32 poolId);

    /// @notice Exact-in quote through the official V4Quoter. NOT view — the quoter simulates
    ///         the swap and reverts to surface the result — so call it onchain right before
    ///         executing, or offchain via eth_call.
    /// @param assetForUsdc true = sell `asset` for USDC (exit); false = buy `asset` with USDC
    /// @param user forwarded as hookData to the pool hook (RWAGateHook compliance check)
    function quoteExactIn(address asset, bool assetForUsdc, uint256 amountIn, address user)
        external
        returns (uint256 amountOut);

    /// @notice Executes exact-in against the asset's pool: pulls tokenIn from msg.sender
    ///         (requires approval), pays tokenOut straight to `recipient`.
    function swapExactIn(
        address asset,
        bool assetForUsdc,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        address user
    ) external returns (uint256 amountOut);
}
