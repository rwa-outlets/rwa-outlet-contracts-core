// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Context} from "swap-vm/src/libs/VM.sol";
import {AquaOpcodes} from "swap-vm/src/opcodes/AquaOpcodes.sol";
import {Controls} from "swap-vm/src/instructions/Controls.sol";
import {XYCSwap} from "swap-vm/src/instructions/XYCSwap.sol";
import {Extruction} from "swap-vm/src/instructions/Extruction.sol";
import {Program, ProgramBuilder} from "swap-vm/test/utils/ProgramBuilder.sol";

import {OutletPrograms} from "../src/libraries/OutletPrograms.sol";
import {NavExtruction} from "../src/NavExtruction.sol";

/// @notice Pins our hardcoded opcode constants to the *official* AquaOpcodes table. If 1inch
///         reorders instructions (they promise append-only), this test fails loudly instead of
///         our programs silently executing the wrong instructions.
contract OutletProgramsTest is Test, AquaOpcodes {
    using ProgramBuilder for Program;

    constructor() AquaOpcodes(address(1)) {}

    function _table() private pure returns (Program memory) {
        return ProgramBuilder.init(_opcodes());
    }

    function test_OpcodeConstantsMatchOfficialTable() public pure {
        Program memory p = _table();
        assertEq(p.findOpcode(Controls._deadline), OutletPrograms.OP_DEADLINE, "deadline");
        assertEq(p.findOpcode(XYCSwap._xycSwapXD), OutletPrograms.OP_XYC_SWAP, "xycSwap");
        assertEq(p.findOpcode(Controls._salt), OutletPrograms.OP_SALT, "salt");
        assertEq(p.findOpcode(Extruction._extruction), OutletPrograms.OP_EXTRUCTION, "extruction");
        assertEq(
            p.findOpcode(Controls._onlyTxOriginTokenBalanceNonZero),
            OutletPrograms.OP_ONLY_TX_ORIGIN_TOKEN_BALANCE_NON_ZERO,
            "txOriginGate"
        );
    }

    function test_ExpressProgramEncoding() public pure {
        address target = address(0xE);
        address asset = address(0xA);
        address quote = address(0xB);
        bytes memory program =
            OutletPrograms.expressProgram(target, 1, asset, quote, 20, 1 days, address(0), 7);

        // [extruction][len][target..extArgs][salt][len][salt8]
        bytes memory extArgs = OutletPrograms.fixedSpreadArgs(1, asset, quote, 20, 1 days);
        bytes memory expected = bytes.concat(
            abi.encodePacked(
                OutletPrograms.OP_EXTRUCTION, uint8(20 + extArgs.length), target, extArgs
            ),
            abi.encodePacked(OutletPrograms.OP_SALT, uint8(8), uint64(7))
        );
        assertEq(program, expected, "express program bytes");
        // NavExtruction FixedSpread args are 48 bytes: mode+poolId+asset+quote+spread+staleness
        assertEq(extArgs.length, 48, "fixed args length");
    }

    function test_GatedProgramPrependsComplianceCheck() public view {
        address nft = address(0xF);
        bytes memory program =
            OutletPrograms.expressProgram(address(0xE), 1, address(0xA), address(0xB), 20, 1 days, nft, 7);
        assertEq(uint8(program[0]), OutletPrograms.OP_ONLY_TX_ORIGIN_TOKEN_BALANCE_NON_ZERO);
        assertEq(uint8(program[1]), 20);
        assertEq(address(bytes20(this.slice(program, 2, 22))), nft);
    }

    function test_MarketProgramOrdering() public pure {
        bytes memory program = OutletPrograms.marketProgram(
            address(0xE), 3, address(0xA), address(0xB), 50, 1 days, address(0), 9
        );
        // xyc prices first, band validates second
        assertEq(uint8(program[0]), OutletPrograms.OP_XYC_SWAP);
        assertEq(uint8(program[1]), 0);
        assertEq(uint8(program[2]), OutletPrograms.OP_EXTRUCTION);
    }

    function test_DecayArgsLength() public pure {
        bytes memory args = OutletPrograms.dutchDecayArgs(
            2, address(0xA), address(0xB), 30, 300, uint40(1000), 3 days, 1 days
        );
        assertEq(args.length, 59, "decay args length");
        assertEq(uint8(args[0]), uint8(NavExtruction.Mode.DutchDecay));
    }

    function slice(bytes calldata data, uint256 start, uint256 end)
        external
        pure
        returns (bytes memory)
    {
        return data[start:end];
    }
}
