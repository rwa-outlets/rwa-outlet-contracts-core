# RWA Outlets — Core Contracts

Instant-liquidity market for tokenized real-world assets, built as a **1inch Aqua app with
SwapVM programs**. Holders of tokenized RWAs exit to USDC (or buy in) in one transaction through
risk-tiered pools, or queue for NAV settlement via ERC-7540 and keep the yield. See
[`docs/01-architecture.md`](docs/01-architecture.md) for the design,
[`docs/02-engine-spec.md`](docs/02-engine-spec.md) for the contract-level spec, and
[`docs/03-contracts.md`](docs/03-contracts.md) for the build list.

The swap engine is the **official 1inch stack used as-is** — Aqua and `AquaSwapVMRouter` are
redeploys of the untouched vendored bytecode, never reimplemented. Custom pricing plugs in only
through the official `_extruction` opcode (`NavExtruction`).

## Deployments — Ethereum Sepolia (11155111)

Machine-readable copy: [`deployments/11155111.json`](deployments/11155111.json).

### Official 1inch stack (redeployed, unmodified)

| Contract | Address |
|---|---|
| Aqua | [`0xA787Dd5eF559569b068283D2617e0D8484C08e9B`](https://sepolia.etherscan.io/address/0xA787Dd5eF559569b068283D2617e0D8484C08e9B) |
| AquaSwapVMRouter | [`0xc4D05Fc049B819DAAf2753d5a0D32402b8a76d47`](https://sepolia.etherscan.io/address/0xc4D05Fc049B819DAAf2753d5a0D32402b8a76d47) |

### RWA Outlets engine

| Contract | Address |
|---|---|
| NavOracle | [`0x49f587A7203C2CE7765CAcdD0D5bf912BF52a692`](https://sepolia.etherscan.io/address/0x49f587A7203C2CE7765CAcdD0D5bf912BF52a692) |
| NavExtruction | [`0xFD8C2d242e82F7Ba28a2a038461C45481EA3849A`](https://sepolia.etherscan.io/address/0xFD8C2d242e82F7Ba28a2a038461C45481EA3849A) |
| ComplianceNFT | [`0x82E0649Ec0783985FeB4201f126783bD4fC31031`](https://sepolia.etherscan.io/address/0x82E0649Ec0783985FeB4201f126783bD4fC31031) |
| OutletRouter | [`0x9C352AE4df4853D25F2691c9183c336E0c112289`](https://sepolia.etherscan.io/address/0x9C352AE4df4853D25F2691c9183c336E0c112289) |
| RedemptionQueue (rwaTBILL) | [`0xBf14ed0b9E2d3A167f9119082440A91C9C810472`](https://sepolia.etherscan.io/address/0xBf14ed0b9E2d3A167f9119082440A91C9C810472) |
| RedemptionQueue (rwaCREDIT) | [`0xb12EE4D7f546C5B6Cb3EcC2b770B9b6780354502`](https://sepolia.etherscan.io/address/0xb12EE4D7f546C5B6Cb3EcC2b770B9b6780354502) |
| CuratorVault — Express tier (roEXP) | [`0x4AaAB2c212dA4d261E5F50F5A97B5d2d3892E204`](https://sepolia.etherscan.io/address/0x4AaAB2c212dA4d261E5F50F5A97B5d2d3892E204) |
| CuratorVault — Patient tier (roPAT) | [`0x4C299f2cE2D07C77e8280a286241e0a30EaD9ae9`](https://sepolia.etherscan.io/address/0x4C299f2cE2D07C77e8280a286241e0a30EaD9ae9) |
| RWAGateHook (Uniswap v4) | [`0x06Ae6eeAfC42d4Ca4158Bd3BddC4B14Cc54948C0`](https://sepolia.etherscan.io/address/0x06Ae6eeAfC42d4Ca4158Bd3BddC4B14Cc54948C0) |

### Demo tokens & faucet

Tokens are dispensed by the faucet; every `drip()` also mints the soulbound ComplianceNFT KYC
pass to visitors who lack one.

| Contract | Address |
|---|---|
| Faucet | [`0xE78E87D994358D17aaf4653d8398f22C93fb758A`](https://sepolia.etherscan.io/address/0xE78E87D994358D17aaf4653d8398f22C93fb758A) |
| TestUSDC (6d) | [`0x062b2F19C852e486b4b913933420957018d1db31`](https://sepolia.etherscan.io/address/0x062b2F19C852e486b4b913933420957018d1db31) |
| rwaTBILL (18d) | [`0x5456E52531085291a35CF0d902aE72D6616b665D`](https://sepolia.etherscan.io/address/0x5456E52531085291a35CF0d902aE72D6616b665D) |
| rwaCREDIT (18d) | [`0xFbca2B3334138C109D51f5101343DE0A35a0eDD9`](https://sepolia.etherscan.io/address/0xFbca2B3334138C109D51f5101343DE0A35a0eDD9) |

External canonical contract: Uniswap v4 `PoolManager` at
[`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543).

Demo parameters: NAVs `rwaTBILL = 1.0021`, `rwaCREDIT = 1.0432`; compressed issuer windows
(60 s ≙ T+7, 90 s ≙ T+90); queue fee 5 bps. All roles (curator, issuer, oracle keeper,
treasuries) are currently the deployer and hand over to the agent/keeper via `setRoles` /
`setKeeper`.

## Build & test

```bash
forge build          # two solc units: 0.8.30 (swap-vm/Aqua) + 0.8.26 (Uniswap v4)
forge test           # 79 tests: unit, fuzz, and ERC-7540 invariant suites
```

Tests run against the official Aqua + `AquaSwapVMRouter` deployed from the vendored 1inch
sources (`test/base/OutletTestBase.sol`), including the `quote() == swap()` extruction duals.

## Deploy

```bash
# .env: MNEMONIC=...
# 1. official 1inch stack via forge create (see script header for why), then:
export AQUA=<aqua> SWAP_VM=<router>
forge script script/Deploy.s.sol --rpc-url $RPC --mnemonics "$MNEMONIC" --sender $DEPLOYER --broadcast
# 2. v4 hook (separate 0.8.26 unit, CREATE2-mined address):
forge script script/DeployHook.s.sol --rpc-url $RPC --mnemonics "$MNEMONIC" --sender $DEPLOYER --broadcast
# (Sepolia used script/RewireFaucetTokens.s.sol to bind the stack to the faucet's live tokens.)
```

Addresses are written to `deployments/<chainid>.json`.
