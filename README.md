# FlowLend – Flow-Native Lending Primitive (Testnet)

FlowLend is a minimal lending protocol built on the **Flow blockchain** to showcase
end-to-end DeFi engineering for the **DeFi Engineer** role at Flow.

Users can:

- Deposit **FLOW** as collateral
- Borrow FLOW against their collateral
- Repay debt and withdraw collateral
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
  - Accrues interest based on block timestamps using a simple
    `interestRatePerSecond`

**Off-chain**

- **Frontend:** Next.js (TypeScript, React)
- **Wallet & Chain:** Flow Client Library (`@onflow/fcl`)
- **UI:** Single-page “FlowLend Dashboard” showing:
  - User position
  - Pool state
  - Health factor + safe borrow / safe withdraw hints
  - Actions: Deposit / Withdraw / Borrow / Repay

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
  - `interestRatePerSecond = 0.000001` (simple per-second interest)
- Core methods:
  - `deposit(fromVault, user)`
  - `withdraw(amount, user): @FlowToken.Vault`
  - `borrow(amount, user): @FlowToken.Vault`
  - `repay(fromVault, user)`
- View methods:
  - `getUserPosition(address)`
  - `getUserHealthFactor(address)`
  - `getPoolState()`
- Events:
  - `Deposit`, `Withdraw`, `Borrow`, `Repay` with new position data

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
    - inline Cadence for deposit/withdraw/borrow/repay
    - shows transaction status until `onceSealed()`

The dashboard is intentionally compact: a hiring manager can load it, connect a
testnet wallet, click Deposit/Borrow, and immediately see the protocol state
update.

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


