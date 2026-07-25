// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ComplianceNFT — soulbound ERC-721 KYC pass (docs/03-contracts.md §2.2)
/// @notice Exists to be read by `balanceOf`-based gates: the stock SwapVM opcodes
///         (`_onlyTakerTokenBalanceNonZero`, `_onlyTxOriginTokenBalanceNonZero`) and
///         `RWAGateHook`. Standard Transfer events give the subgraph the KYC set for free.
contract ComplianceNFT is ERC721, Ownable {
    uint256 private _nextId = 1;

    mapping(address operator => bool) public isOperator;
    mapping(address holder => uint256) public tokenOf;

    event OperatorSet(address indexed operator, bool allowed);

    error NotOperator();
    error AlreadyVerified(address holder);
    error NotVerified(address holder);
    error Soulbound();

    modifier onlyOperator() {
        if (!isOperator[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor() ERC721("RWA Outlets KYC Pass", "rwaKYC") Ownable(msg.sender) {}

    function setOperator(address operator, bool allowed) external onlyOwner {
        isOperator[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Issue a pass. One per address; contracts (queue, vaults, routers) can hold one too.
    function mint(address to) external onlyOperator returns (uint256 id) {
        if (balanceOf(to) != 0) revert AlreadyVerified(to);
        id = _nextId++;
        tokenOf[to] = id;
        _mint(to, id); // deliberate _mint: passes go to contracts without onERC721Received
    }

    /// @notice Revoke a holder's pass (burns their token).
    function revoke(address holder) external onlyOperator {
        uint256 id = tokenOf[holder];
        if (id == 0) revert NotVerified(holder);
        delete tokenOf[holder];
        _burn(id);
    }

    /// @dev Soulbound: only mint (from == 0) and burn (to == 0) are allowed.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }
}
