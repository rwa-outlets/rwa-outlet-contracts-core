// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC7575 — Multi-Asset ERC-4626 Vaults (vault side)
/// @notice The full ERC-4626 surface minus the ERC-20 requirement, plus `share()` for
///         vaults whose share is an external token. `type(IERC7575).interfaceId ==
///         0x2f0a18c5`, the ID EIP-7575 requires `supportsInterface` to acknowledge
///         (asserted against the EIP constant in the test suite).
interface IERC7575 {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    function asset() external view returns (address assetTokenAddress);
    function share() external view returns (address shareTokenAddress);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function totalAssets() external view returns (uint256 totalManagedAssets);

    function maxDeposit(address receiver) external view returns (uint256 maxAssets);
    function previewDeposit(uint256 assets) external view returns (uint256 shares);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function maxMint(address receiver) external view returns (uint256 maxShares);
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256 maxAssets);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function maxRedeem(address owner) external view returns (uint256 maxShares);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
