// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title NavOracle — per-asset NAV pushed by a keeper
/// @notice Consumers read raw values and decide staleness themselves (docs/03-contracts.md §2.1).
///         Ported unchanged from the validated `rwa-outlets-redemption_queue_simulation` prototype.
contract NavOracle is Ownable {
    struct NavPoint {
        uint216 nav1e18;
        uint40 updatedAt;
    }

    mapping(address asset => NavPoint) private _nav;
    mapping(address keeper => bool) public isKeeper;

    event NavUpdated(address indexed asset, uint256 nav, uint256 timestamp);
    event KeeperSet(address indexed keeper, bool allowed);

    error NotKeeper();
    error NavNotSet(address asset);
    error ZeroNav();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        isKeeper[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    function setNav(address asset, uint256 nav1e18) external onlyKeeper {
        if (nav1e18 == 0 || nav1e18 > type(uint216).max) revert ZeroNav();
        // forge-lint: disable-next-line(unsafe-typecast)
        _nav[asset] = NavPoint(uint216(nav1e18), uint40(block.timestamp));
        emit NavUpdated(asset, nav1e18, block.timestamp);
    }

    function navOf(address asset) external view returns (uint256 nav1e18, uint40 updatedAt) {
        NavPoint memory p = _nav[asset];
        if (p.nav1e18 == 0) revert NavNotSet(asset);
        return (p.nav1e18, p.updatedAt);
    }
}
