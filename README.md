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
| OutletRouter | [`0x139EAb630E311C278493b0B1fa392871d0c014BF`](https://sepolia.etherscan.io/address/0x139EAb630E311C278493b0B1fa392871d0c014BF) |
| RedemptionQueue (rwaTBILL) | [`0x782Ee6AA667022A90b5b5522781Ad19aA6C9eD2D`](https://sepolia.etherscan.io/address/0x782Ee6AA667022A90b5b5522781Ad19aA6C9eD2D) |
| RedemptionQueue (rwaCREDIT) | [`0x8eCaFB95ff1E251A9198a766DbECD626bC1d6431`](https://sepolia.etherscan.io/address/0x8eCaFB95ff1E251A9198a766DbECD626bC1d6431) |
| CuratorVault — Express tier (roEXP) | [`0x4AaAB2c212dA4d261E5F50F5A97B5d2d3892E204`](https://sepolia.etherscan.io/address/0x4AaAB2c212dA4d261E5F50F5A97B5d2d3892E204) |
| CuratorVault — Patient tier (roPAT) | [`0x4C299f2cE2D07C77e8280a286241e0a30EaD9ae9`](https://sepolia.etherscan.io/address/0x4C299f2cE2D07C77e8280a286241e0a30EaD9ae9) |
| RWAGateHook (Uniswap v4) | [`0x06Ae6eeAfC42d4Ca4158Bd3BddC4B14Cc54948C0`](https://sepolia.etherscan.io/address/0x06Ae6eeAfC42d4Ca4158Bd3BddC4B14Cc54948C0) |

### Uniswap v4 lane

Machine-readable copy: [`deployments/11155111.v4.json`](deployments/11155111.v4.json). Both
RWA/USDC pools (fee 3000, tick spacing 60, hook = RWAGateHook) are initialized at live NAV
with full-range demo liquidity; the OutletRouter carries their TWAP guards (15 min window,
100 bps band).

| Contract | Address |
|---|---|
| V4Venue | [`0xf15b24dF29145A35E446e162e247102f5C77C0B4`](https://sepolia.etherscan.io/address/0xf15b24dF29145A35E446e162e247102f5C77C0B4) |
| V4Quoter (official, redeployed) | [`0x98916b10a620b7Bc2911207932AE199C85513Dd1`](https://sepolia.etherscan.io/address/0x98916b10a620b7Bc2911207932AE199C85513Dd1) |
| V4LpRouter (demo LP helper) | [`0x20aD784b3897735968C64b784aa68084ae870567`](https://sepolia.etherscan.io/address/0x20aD784b3897735968C64b784aa68084ae870567) |

Pool IDs: rwaTBILL `0x48339bc61c57f8d92b59c94a5ca2e8f0955d8178be250cd7210b217fed867b97`,
rwaCREDIT `0x3b929335bdb462d89381183305cc59a2915ff476684ad4b9b5e70afdf8423fce`.
`script/run-v4-swaps.sh` pushes hook-gated swaps through both pools (seeds the
`ObservationRecorded` TWAP series).

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
forge test           # 93 tests: unit, fuzz, and ERC-7540 invariant suites
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
# 3. v4 pools + venue: initializes both RWA/USDC pools at NAV with the hook, seeds demo
#    liquidity, registers them on V4Venue, wires OutletRouter (fallback venue + TWAP guard):
forge script script/SetupV4Pool.s.sol --rpc-url $RPC --mnemonics "$MNEMONIC" --sender $DEPLOYER --broadcast
# (Sepolia used script/RewireFaucetTokens.s.sol to bind the stack to the faucet's live tokens.)
```

Addresses are written to `deployments/<chainid>.json` (v4 lane: `deployments/<chainid>.v4.json`).

## Uniswap integration (hackathon judges — where to look)

Onchain half of the Uniswap track ([frontend repo](https://github.com/rwa-outlets/frontend) holds
the **Trading API** half + `FEEDBACK.md`):

- [`src/RWAGateHook.sol`](src/RWAGateHook.sol) — custom v4 hook on the RWA/USDC pool:
  `beforeSwap`/`beforeAddLiquidity` compliance gate over a soulbound KYC NFT (user forwarded via
  `hookData`), `afterSwap` cumulative-price oracle with `twapRate(poolId, window)`.
- [`src/V4Venue.sol`](src/V4Venue.sol) — v4 execution leg: per-asset pool registry, exact-in
  quotes via the official `V4Quoter`, swaps settled in its own `unlockCallback`
  (swap → settle input → take output straight to the user).
- [`src/OutletRouter.sol`](src/OutletRouter.sol) — best-of routing: `quoteInstantAll`/`quoteBuyAll`
  arbitrate our Aqua/SwapVM pools against the v4 pool; `redeemInstant`/`buy` execute the winner;
  program quotes are sanity-bounded by the hook's TWAP (`_checkTwapBand`).
- Tests: [`test/RWAGateHook.t.sol`](test/RWAGateHook.t.sol),
  [`test/V4Venue.t.sol`](test/V4Venue.t.sol) (real `PoolManager` + `V4Quoter`),
  router×v4 routing in [`test/OutletRouter.t.sol`](test/OutletRouter.t.sol).
