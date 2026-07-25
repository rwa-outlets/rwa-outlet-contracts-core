// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {NavExtruction} from "../NavExtruction.sol";

/// @title OutletPrograms — SwapVM program encoding for the three outlet pools
/// @notice Programs are `[opcode:1][argsLength:1][args]` sequences executed by the official
///         `AquaSwapVMRouter`. Opcode indexes below mirror the official `AquaOpcodes` table and
///         are asserted against it in `test/OutletPrograms.t.sol` — if 1inch appends opcodes the
///         constants stay valid (their table is append-only for backward compatibility).
library OutletPrograms {
    uint8 internal constant OP_DEADLINE = 14;
    uint8 internal constant OP_XYC_SWAP = 18;
    uint8 internal constant OP_SALT = 21;
    uint8 internal constant OP_EXTRUCTION = 33;
    uint8 internal constant OP_ONLY_TX_ORIGIN_TOKEN_BALANCE_NON_ZERO = 34;

    error ArgsTooLong(uint256 length);

    function instr(uint8 opcode, bytes memory args) internal pure returns (bytes memory) {
        if (args.length > type(uint8).max) revert ArgsTooLong(args.length);
        return abi.encodePacked(opcode, uint8(args.length), args);
    }

    // ------------------------------------------------------------ instructions

    /// @dev Strategy uniqueness: identical pool params must still hash to distinct orders.
    function saltInstr(uint64 salt) internal pure returns (bytes memory) {
        return instr(OP_SALT, abi.encodePacked(salt));
    }

    /// @dev Hard strategy expiry (`Controls._deadline`), 5-byte timestamp.
    function deadlineInstr(uint40 deadline) internal pure returns (bytes memory) {
        return instr(OP_DEADLINE, abi.encodePacked(deadline));
    }

    /// @dev KYC gate: `Controls._onlyTxOriginTokenBalanceNonZero(complianceNFT)`. tx.origin
    ///      (the end user, even when routed through OutletRouter) must hold the pass.
    function complianceGateInstr(address complianceNFT) internal pure returns (bytes memory) {
        return instr(OP_ONLY_TX_ORIGIN_TOKEN_BALANCE_NON_ZERO, abi.encodePacked(complianceNFT));
    }

    /// @dev Constant-product swap over the maker's Aqua virtual balances (no args).
    function xycSwapInstr() internal pure returns (bytes memory) {
        return instr(OP_XYC_SWAP, "");
    }

    function extructionInstr(address target, bytes memory extArgs) internal pure returns (bytes memory) {
        return instr(OP_EXTRUCTION, abi.encodePacked(target, extArgs));
    }

    // -------------------------------------------------------- extruction args

    function fixedSpreadArgs(
        uint8 poolId,
        address asset,
        address quote,
        uint16 spreadBps,
        uint32 maxStaleness
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(NavExtruction.Mode.FixedSpread), poolId, asset, quote, spreadBps, maxStaleness
        );
    }

    function dutchDecayArgs(
        uint8 poolId,
        address asset,
        address quote,
        uint16 startBps,
        uint16 floorBps,
        uint40 startTime,
        uint32 duration,
        uint32 maxStaleness
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(NavExtruction.Mode.DutchDecay),
            poolId,
            asset,
            quote,
            startBps,
            floorBps,
            startTime,
            duration,
            maxStaleness
        );
    }

    function navBandArgs(
        uint8 poolId,
        address asset,
        address quote,
        uint16 bandBps,
        uint32 maxStaleness
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint8(NavExtruction.Mode.NavBand), poolId, asset, quote, bandBps, maxStaleness
        );
    }

    // ------------------------------------------------------------- pool programs

    /// @notice Pool 1 — Express: NAV − fixed spread, both directions, partial fills bounded by
    ///         shipped inventory.
    function expressProgram(
        address navExtruction,
        uint8 poolId,
        address asset,
        address quote,
        uint16 spreadBps,
        uint32 maxStaleness,
        address complianceNFT, // zero = ungated
        uint64 salt
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            complianceNFT == address(0) ? bytes("") : complianceGateInstr(complianceNFT),
            extructionInstr(
                navExtruction, fixedSpreadArgs(poolId, asset, quote, spreadBps, maxStaleness)
            ),
            saltInstr(salt)
        );
    }

    /// @notice Pool 2 — Patient: exit-only Dutch decay auction; expires at
    ///         `startTime + duration` (instruction-level revert, no invalidators needed).
    function patientProgram(
        address navExtruction,
        uint8 poolId,
        address asset,
        address quote,
        uint16 startBps,
        uint16 floorBps,
        uint40 startTime,
        uint32 duration,
        uint32 maxStaleness,
        address complianceNFT,
        uint64 salt
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            complianceNFT == address(0) ? bytes("") : complianceGateInstr(complianceNFT),
            extructionInstr(
                navExtruction,
                dutchDecayArgs(
                    poolId, asset, quote, startBps, floorBps, startTime, duration, maxStaleness
                )
            ),
            saltInstr(salt)
        );
    }

    /// @notice Pool 3 — Market: two-sided xyc AMM over the maker's shipped balances with a
    ///         NAV-band post-check (`_xycSwapXD` prices, NavExtruction validates).
    function marketProgram(
        address navExtruction,
        uint8 poolId,
        address asset,
        address quote,
        uint16 bandBps,
        uint32 maxStaleness,
        address complianceNFT,
        uint64 salt
    ) internal pure returns (bytes memory) {
        return bytes.concat(
            complianceNFT == address(0) ? bytes("") : complianceGateInstr(complianceNFT),
            xycSwapInstr(),
            extructionInstr(navExtruction, navBandArgs(poolId, asset, quote, bandBps, maxStaleness)),
            saltInstr(salt)
        );
    }
}
