# FlowLend – Flow-Native Lending Primitive (Testnet)

FlowLend is a minimal lending protocol built on the **Flow blockchain** to showcase
end-to-end DeFi engineering for the **DeFi Engineer** role at Flow.

Users can:

- Deposit **FLOW** as collateral
- Borrow FLOW against their collateral with a utilization-based rate curve
- Repay debt, withdraw collateral, or liquidate unhealthy positions
- Execute flash loans via a built-in receiver demo
- View health factor, utilization, and pool-level analytics in a single dashboard

The project demonstrates **Cadence smart contracts**, **DeFi risk modeling**, and
a **Next.js + FCL** front-end wired to Flow testnet.

---

## High-Level Architecture

**On-chain**

- `FlowLend.cdc` – Cadence contract deployed on Flow testnet
  - Tracks per-user positions (`collateral`, `borrowed`)
  - Maintains global totals (`totalCollateral`, `totalBorrows`)
  - Computes:
    - Health factor per user: `(collateral * collateralFactor) / borrowed`
    - Utilization rate: `totalBorrows / totalCollateral`
  - Accrues interest using an Aave-style utilization curve (base + slope1/slope2)
  - Supports liquidations with bonuses and emits `Liquidation` + `FlashLoan` events
  - Provides flash-loan primitive + demo receiver resource

**Off-chain**

- **Frontend:** Next.js (TypeScript, React)
- **Wallet & Chain:** Flow Client Library (`@onflow/fcl`)
- **UI:** Single-page “FlowLend Dashboard” showing:
  - User position
  - Pool state
  - Health factor + safe borrow / safe withdraw hints
  - Actions: Deposit / Withdraw / Borrow / Repay / Liquidate / Flash loan demo

---

## Smart Contract Design

**File:** `cadence/contracts/FlowLend.cdc`

Key components:

- `UserPosition`
  - `collateral: UFix64`
  - `borrowed: UFix64`
- `PoolState`
  - `totalCollateral`
  - `totalBorrows`
  - `utilizationRate`
- Risk parameters:
  - `collateralFactor = 0.75` (75% LTV)
  - `liquidationThreshold = 1.05` (must keep HF ≥ 1.05)
  - Utilization model:
    - Base rate (`getBaseRatePerSecond`)
    - Slope1 before target utilization (`getSlope1PerSecond`)
    - Slope2 after target utilization (`getSlope2PerSecond`)
    - Target utilization = 80%
- Price-aware risk math via `getFlowPrice()` helper (stubbed to `1.0` now, ready for oracles)
- Core methods:
  - `deposit`, `withdraw`, `borrow`, `repay`
  - `liquidate` – repays borrower debt, seizes collateral + bonus
  - `flashLoan` – atomic loan that must be repaid within the transaction
- Demo helpers:
  - `createDemoFlashLoanReceiver()` to showcase Flow-native flash loans
- View methods:
  - `getUserPosition(address)`
  - `getUserHealthFactor(address)`
  - `getPoolState()`
- Events:
  - `Deposit`, `Withdraw`, `Borrow`, `Repay`, `Liquidation`, `FlashLoan`

**Security / correctness considerations**

- Uses Flow’s **capability-based security** and `FlowToken.Vault` APIs
- Enforces:
  - non-zero amounts for all actions
  - collateral balance checks on withdraw
  - health factor checks on withdraw/borrow (cannot make the position unhealthy)
  - pool liquidity checks before borrow
- Applies global interest accrual before each state-changing action using
  `getCurrentBlock().timestamp`
- For simplicity, interest is applied by scaling all positions rather than using
  a complex index model (not gas-optimized, but good for clarity and interviews)

---

## Frontend & FCL Integration

**File:** `app/src/app/page.tsx`

- Uses a small custom hook (`useFlowUser`) to:
  - initialize FCL config
  - subscribe to `currentUser`
  - provide `logIn()` and `logOut()`
- Uses FCL:
  - `fcl.query` to call Cadence **scripts** that read user position, health
    factor, and pool state
  - `fcl.mutate` to submit **transactions** directly from the UI:
    - inline Cadence for deposit / withdraw / borrow / repay / liquidate / flash loan demo
    - shows transaction status until `onceSealed()`

The dashboard is intentionally compact: a hiring manager can load it, connect a
testnet wallet, click Deposit/Borrow, and immediately see the protocol state
update.

---

## Consumer DeFi & Sponsored UX

FlowLend is designed with **consumer-scale DeFi** in mind.

Most users should not have to think about faucets, gas tokens, or which account
is paying fees. To reflect Flow’s vision of “onboarding the next billion people
into crypto,” the dApp includes a **Sponsored Mode (gasless UX preview)**:

- The UI exposes a Normal vs Sponsored toggle.
- In Normal mode, users sign transactions directly from their Flow wallet via
  FCL.
- In Sponsored mode, the app simulates a path where a **relayer or wallet
  sponsor** (e.g., Blocto) would pay transaction fees on behalf of the user.

In this demo implementation, both modes still use FCL for signing, but the React
`sendTx` helper and UI wiring clearly mark where a production integration would
call a backend relayer or Flow’s account-abstraction sponsorship APIs.

The intent is to show how FlowLend evolves into a **one-click, gasless
experience** where end users only see:

- available liquidity
- their health factor
- clear Deposit / Borrow / Repay / Liquidate actions

while the protocol + wallet infrastructure handle gas and routing under the hood.

This narrative ties directly into Flow’s product messaging: **consumer-ready UX,
gasless pathways, and onboarding the next billion users.**

---

## Advanced Protocol Features

FlowLend has evolved into a small **DeFi lab on Flow testnet**, designed to show
what a production-grade money market and yield layer could look like for consumer
DeFi.

### Utilization-based Interest Model

Instead of a fixed borrow rate, FlowLend derives **borrow APR from pool
utilization** using a two-slope curve:

- Below a target utilization, rates ramp up gradually from a base rate.
- Above target, an additional slope makes borrowing more expensive and encourages
  deleveraging.

Every borrower position is scaled whenever interest accrues, and the model lives
entirely in helpers so we can safely upgrade parameters on testnet without
changing stored state.

### Liquidation Engine

Under-collateralized positions are now **actively liquidatable**:

- Health factor and liquidation checks run through a price-aware
  `computeHealthFactor` helper (via `getFlowPrice()`).
- Liquidators repay part of a borrower’s debt and seize
  `repay * (1 + liquidationBonus)` collateral.
- A `Liquidation` event emits full accounting so off-chain bots or services can
  monitor insolvency and liquidations in real time.

### Flash Loan Primitive

FlowLend exposes a native **flashLoan** entrypoint that:

- Withdraws a configurable amount from protocol liquidity.
- Invokes any resource implementing `FlashLoanReceiver`.
- Requires the pool balance to be at least whole at the end of the call or the
  transaction reverts.

A built-in `DemoFlashLoanReceiver` and `flash_loan_demo.cdc` transaction
demonstrate Flow’s **atomic, fee-free intra-transaction borrowing** without
touching user wallets.

### Price-aware Risk Model

All risk math flows through a stubbed `getFlowPrice()` helper, which currently
returns `1.0` but is designed to plug into Flow-native or oracle feeds (e.g.
Pyth) without changing stored state. Health factor, LTV, and liquidation logic
are all written in price terms so migrating to a multi-asset, oracle-backed
version is straightforward.

### Consumer DeFi & Sponsored UX

The dApp includes a **“Normal vs Sponsored” UX toggle**:

- In Normal mode, users sign transactions directly via FCL.
- In Sponsored mode, the app simulates a **gasless relayer path** and labels all
  transaction status with a `[Sponsored preview]` prefix.

The React wiring documents exactly where a production deployment would integrate
a wallet sponsor or protocol-owned relayer to deliver **one-click, gasless
interactions** that match Flow’s mission to **onboard the next billion people
into crypto**.

### Liquid Staking (sFLOW)

The repository also includes a separate **FlowLiquidStaking** contract:

- Users stake FLOW into a protocol-owned vault and mint sFLOW balances tracked
  on-chain.
- A time-based interest model grows `totalStaked` over time.
- The sFLOW ↔ FLOW exchange rate is derived from `totalStaked / sSupply`.
- Redeeming sFLOW burns the user’s balance and returns FLOW at the current rate.

This demonstrates LST-style mechanics on Flow and how lending markets and
staking yield layers can coexist in a single protocol suite.

---

## Liquid Staking (sFLOW)

The repo also ships with `FlowLiquidStaking.cdc`, a standalone contract that
demonstrates Flow-native liquid staking mechanics:

- Users stake FLOW into a protocol-owned vault and mint sFLOW receipt balances.
- A simple on-chain interest model grows `totalStaked` over time, lifting the
  sFLOW ↔ FLOW exchange rate (`totalStaked / sSupply`).
- Redeeming sFLOW burns the user’s balance and withdraws the underlying FLOW at
  the latest rate.
- Scripts and transactions (`stake_flow.cdc`, `redeem_flow.cdc`,
  `get_staking_state.cdc`) showcase the full lifecycle.

This mirrors LST patterns from other ecosystems and shows how Flow can offer
consumer-friendly staking yield alongside FlowLend’s borrowing markets.

---

## Running Locally

```bash
git clone https://github.com/<your-username>/flowlend.git
cd flowlend/app
npm install
npm run dev
```

Then open http://localhost:3000 and:

- Connect a Flow testnet wallet via FCL
- Make sure your account has some testnet FLOW
- Use the Deposit / Borrow actions and watch the dashboard update

The Cadence contract and scripts/transactions live under `cadence/`.


