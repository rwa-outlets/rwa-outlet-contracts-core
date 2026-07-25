// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title RWAToken — 18-decimals issuer-mintable tokenized RWA
/// @notice The queue's external ERC-7575 share (docs/03-contracts.md §2.4). Owner = issuer.
///         Optionally compliance-gated: when `gated`, receiving a transfer requires holding
///         the ComplianceNFT — the "hard" KYC line on top of the program-level gates.
contract RWAToken is ERC20, Ownable {
    IERC721 public immutable compliance;
    bool public gated;

    event GatedSet(bool gated);

    error ReceiverNotVerified(address receiver);

    constructor(string memory name_, string memory symbol_, IERC721 compliance_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        compliance = compliance_;
    }

    /// @notice Issuer toggles hard transfer gating (requires a compliance registry to be set).
    function setGated(bool gated_) external onlyOwner {
        require(address(compliance) != address(0) || !gated_, ReceiverNotVerified(address(0)));
        gated = gated_;
        emit GatedSet(gated_);
    }

    /// @notice Issuer mints new RWA supply (e.g. against offchain subscriptions).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Issuer burns redeemed supply (called after settlement at NAV).
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /// @dev Mint and burn are always allowed; regular transfers require the receiver to
    ///      hold a compliance pass when gating is on.
    function _update(address from, address to, uint256 value) internal override {
        if (gated && from != address(0) && to != address(0)) {
            if (compliance.balanceOf(to) == 0) revert ReceiverNotVerified(to);
        }
        super._update(from, to, value);
    }
}
