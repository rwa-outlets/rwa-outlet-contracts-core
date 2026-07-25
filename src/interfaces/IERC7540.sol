// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC7540Operator — ERC-7540 operator model
/// @notice `type(IERC7540Operator).interfaceId == 0xe3bc4e65`, which EIP-7540 requires all
///         asynchronous vaults to acknowledge via `supportsInterface` (asserted against the
///         EIP constant in the test suite).
interface IERC7540Operator {
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    function setOperator(address operator, bool approved) external returns (bool success);
    function isOperator(address controller, address operator) external view returns (bool status);
}

/// @title IERC7540Redeem — ERC-7540 asynchronous redemption flow
/// @notice `type(IERC7540Redeem).interfaceId == 0x620ee8e4`, which EIP-7540 requires
///         asynchronous redemption vaults to acknowledge via `supportsInterface`.
interface IERC7540Redeem is IERC7540Operator {
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares);
}
