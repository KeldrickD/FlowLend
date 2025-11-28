"use client";

import { useEffect, useState } from "react";
import * as fcl from "@onflow/fcl";
import { useFlowUser } from "../hooks/useFlowUser";

type UserPosition = {
  collateral: string;
  borrowed: string;
};

type PoolState = {
  totalCollateral: string;
  totalBorrows: string;
  utilizationRate: string;
};

type CadenceArgsBuilder = (arg: typeof fcl.arg, t: typeof fcl.t) => unknown[];

const COLLATERAL_FACTOR = 0.75;
const LIQ_THRESHOLD = 1.05;

const parseFlow = (value?: string | null) => {
  const parsed = Number.parseFloat(value ?? "0");
  return Number.isFinite(parsed) ? parsed : 0;
};

const computeHealthFactor = (collateral: number, borrowed: number) => {
  if (borrowed <= 0) return Number.POSITIVE_INFINITY;
  return (collateral * COLLATERAL_FACTOR) / borrowed;
};

const computeMaxBorrowable = (collateral: number, borrowed: number) => {
  const maxDebt = (collateral * COLLATERAL_FACTOR) / LIQ_THRESHOLD;
  return Math.max(0, maxDebt - borrowed);
};

const computeMaxWithdrawable = (collateral: number, borrowed: number) => {
  if (borrowed <= 0) return Math.max(0, collateral);
  const minCollateralNeeded = (borrowed * LIQ_THRESHOLD) / COLLATERAL_FACTOR;
  return Math.max(0, collateral - minCollateralNeeded);
};

export default function HomePage() {
  const { user, loading, logIn, logOut } = useFlowUser();
  const [userPosition, setUserPosition] = useState<UserPosition | null>(null);
  const [poolState, setPoolState] = useState<PoolState | null>(null);
  const [healthFactor, setHealthFactor] = useState<string | null>(null);
  const [amount, setAmount] = useState("1.0");
  const [txStatus, setTxStatus] = useState<string | null>(null);
  const [loadingData, setLoadingData] = useState(false);

  const isLoggedIn = Boolean(user?.addr);

  const formatted = (val?: string | null) =>
    val ? Number.parseFloat(val).toFixed(4) : "0.0000";

  const fetchData = async () => {
    if (!user?.addr) return;
    const userAddress = user.addr;
    if (!userAddress) return;
    setLoadingData(true);
    try {
      const pos = await fcl.query({
        cadence: `
          import FlowLend from 0xFlowLend

          access(all) fun main(user: Address): FlowLend.UserPosition {
              return FlowLend.getUserPosition(user: user)
          }
        `,
        args: (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(userAddress, t.Address)],
      });

      const hf = await fcl.query({
        cadence: `
          import FlowLend from 0xFlowLend

          access(all) fun main(user: Address): UFix64 {
              return FlowLend.getUserHealthFactor(user: user)
          }
        `,
        args: (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(userAddress, t.Address)],
      });

      const pool = await fcl.query({
        cadence: `
          import FlowLend from 0xFlowLend

          access(all) fun main(): FlowLend.PoolState {
              return FlowLend.getPoolState()
          }
        `,
      });

      setUserPosition({
        collateral: pos.collateral,
        borrowed: pos.borrowed,
      });
      setHealthFactor(hf.toString());
      setPoolState({
        totalCollateral: pool.totalCollateral,
        totalBorrows: pool.totalBorrows,
        utilizationRate: pool.utilizationRate,
      });
    } catch (err) {
      console.error("Error fetching FlowLend data", err);
    } finally {
      setLoadingData(false);
    }
  };

  useEffect(() => {
    if (isLoggedIn) {
      fetchData();
    } else {
      setUserPosition(null);
      setPoolState(null);
      setHealthFactor(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoggedIn]);

  const formatTxError = (err: Error) => {
    const message = err.message ?? "";
    if (message.includes("Cannot withdraw tokens")) {
      return "Error: Not enough FLOW in your wallet for that amount. Lower the amount or top up via faucet.";
    }
    if (message.includes("would make position unhealthy")) {
      return "Error: This action would push your health factor below the limit. Adjust the amount or add more collateral.";
    }
    return `Error: ${message}`;
  };

  const normalizeFix64 = (input: string) => {
    let value = input.trim();
    if (value.length === 0) {
      return "0.0";
    }
    if (value.startsWith(".")) {
      value = `0${value}`;
    }
    if (!value.includes(".")) {
      value = `${value}.0`;
    }
    if (value.endsWith(".")) {
      value = `${value}0`;
    }
    return value;
  };

  const sendTx = async (
    cadence: string,
    argsBuilder?: CadenceArgsBuilder,
  ) => {
    try {
      setTxStatus("Pending…");
      const txId = await fcl.mutate({
        cadence,
        args: argsBuilder,
        limit: 9999,
      });
      setTxStatus(`Submitted: ${txId}`);
      const result = await fcl.tx(txId).onceSealed();
      setTxStatus(`Sealed: ${result.statusString}`);
      await fetchData();
    } catch (err: unknown) {
      console.error("Flow transaction error", err);
      if (err instanceof Error) {
        setTxStatus(formatTxError(err));
      } else {
        setTxStatus("Error: Unknown failure");
      }
    }
  };

  const handleDeposit = () => {
    const normalizedAmount = normalizeFix64(amount);
    sendTx(
      `
        import FungibleToken from 0xFungibleToken
        import FlowToken from 0xFlowToken
        import FlowLend from 0xFlowLend

        transaction(amount: UFix64) {
            prepare(acct: auth(Storage) &Account) {
                let vaultRef = acct.storage
                    .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                        from: /storage/flowTokenVault
                    ) ?? panic("Could not borrow reference to FLOW vault")

                let payment <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault
                FlowLend.deposit(fromVault: <- payment, user: acct.address)
            }
        }
      `,
      (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(normalizedAmount, t.UFix64)],
    );
  };

  const handleWithdraw = () => {
    const normalizedAmount = normalizeFix64(amount);
    sendTx(
      `
        import FlowToken from 0xFlowToken
        import FlowLend from 0xFlowLend

        transaction(amount: UFix64) {
            prepare(acct: auth(Storage) &Account) {
                let userVaultRef = acct.storage
                    .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
                    ?? panic("Could not borrow reference to FLOW vault")

                let outVault <- FlowLend.withdraw(amount: amount, user: acct.address)
                userVaultRef.deposit(from: <- outVault)
            }
        }
      `,
      (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(normalizedAmount, t.UFix64)],
    );
  };

  const handleBorrow = () => {
    const normalizedAmount = normalizeFix64(amount);
    sendTx(
      `
        import FlowToken from 0xFlowToken
        import FlowLend from 0xFlowLend

        transaction(amount: UFix64) {
            prepare(acct: auth(Storage) &Account) {
                let userVaultRef = acct.storage
                    .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
                    ?? panic("Could not borrow reference to FLOW vault")

                let borrowedVault <- FlowLend.borrow(amount: amount, user: acct.address)
                userVaultRef.deposit(from: <- borrowedVault)
            }
        }
      `,
      (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(normalizedAmount, t.UFix64)],
    );
  };

  const handleRepay = () => {
    const normalizedAmount = normalizeFix64(amount);
    sendTx(
      `
        import FungibleToken from 0xFungibleToken
        import FlowToken from 0xFlowToken
        import FlowLend from 0xFlowLend

        transaction(amount: UFix64) {
            prepare(acct: auth(Storage) &Account) {
                let userVaultRef = acct.storage
                    .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                        from: /storage/flowTokenVault
                    ) ?? panic("Could not borrow reference to FLOW vault")

                let payment <- userVaultRef.withdraw(amount: amount) as! @FlowToken.Vault
                FlowLend.repay(fromVault: <- payment, user: acct.address)
            }
        }
      `,
      (arg: typeof fcl.arg, t: typeof fcl.t) => [arg(normalizedAmount, t.UFix64)],
    );
  };

  return (
    <main className="min-h-screen bg-slate-950 text-slate-50 flex flex-col items-center p-6 gap-6">
      <header className="w-full max-w-4xl flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
        <div>
          <p className="text-sm uppercase tracking-wide text-emerald-400">
            Flow testnet demo
          </p>
          <h1 className="text-3xl font-semibold">FlowLend Dashboard</h1>
          <p className="text-sm text-slate-400">
            Manage your collateralized FLOW loans in a single panel.
          </p>
        </div>
        <div>
          {loading ? (
            <span className="text-sm text-slate-400">Connecting…</span>
          ) : isLoggedIn ? (
            <button
              onClick={logOut}
              className="px-3 py-2 text-sm bg-slate-800 rounded-lg border border-slate-700"
            >
              {user?.addr?.slice(0, 6)}…{user?.addr?.slice(-4)} · Logout
            </button>
          ) : (
            <button
              onClick={logIn}
              className="px-3 py-2 text-sm bg-emerald-500 rounded-lg text-black font-medium"
            >
              Connect Flow Wallet
            </button>
          )}
        </div>
      </header>

      {isLoggedIn && (
        <>
          {(() => {
            const collateral = parseFlow(userPosition?.collateral);
            const borrowed = parseFlow(userPosition?.borrowed);
            const maxBorrow = computeMaxBorrowable(collateral, borrowed);
            const maxWithdraw = computeMaxWithdrawable(collateral, borrowed);
            const currentHF = computeHealthFactor(collateral, borrowed);

            return (
              <section className="w-full max-w-4xl rounded-xl border border-slate-800 bg-emerald-500/10 text-emerald-200 px-4 py-3 text-sm">
                <p>
                  Health factor formula:{" "}
                  <span className="font-mono text-emerald-100">
                    (Collateral × {COLLATERAL_FACTOR}) ÷ Borrowed
                  </span>
                  . You must stay ≥ {LIQ_THRESHOLD.toFixed(2)}.
                </p>
                <p className="mt-1">
                  Current HF:{" "}
                  <span className="font-semibold text-emerald-100">
                    {currentHF === Number.POSITIVE_INFINITY
                      ? "∞"
                      : currentHF.toFixed(3)}
                  </span>
                  . Max borrow you can add now:{" "}
                  <span className="font-mono">{formatted(String(maxBorrow))} FLOW</span>
                  . Safe withdraw available:{" "}
                  <span className="font-mono">
                    {formatted(String(maxWithdraw))} FLOW
                  </span>
                  .
                </p>
              </section>
            );
          })()}

          <section className="w-full max-w-4xl grid gap-4 md:grid-cols-2">
            <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
              <div className="flex items-center justify-between mb-2">
                <h2 className="font-semibold">Your Position</h2>
                <button
                  onClick={fetchData}
                  className="text-xs px-2 py-1 border border-slate-700 rounded-md"
                >
                  Refresh
                </button>
              </div>
              {loadingData && (
                <p className="text-sm text-slate-400">Refreshing…</p>
              )}
              <p className="text-sm">
                Collateral:{" "}
                <span className="font-mono">
                  {formatted(userPosition?.collateral)} FLOW
                </span>
              </p>
              <p className="text-sm">
                Borrowed:{" "}
                <span className="font-mono">
                  {formatted(userPosition?.borrowed)} FLOW
                </span>
              </p>
              <p className="text-sm">
                Health Factor:{" "}
                <span className="font-mono">
                  {healthFactor
                    ? Number.parseFloat(healthFactor).toFixed(3)
                    : "—"}
                </span>
              </p>
            </div>

            <div className="rounded-xl border border-slate-800 bg-slate-900/40 p-4">
              <h2 className="font-semibold mb-2">Pool State</h2>
              <p className="text-sm">
                Total Collateral:{" "}
                <span className="font-mono">
                  {formatted(poolState?.totalCollateral)} FLOW
                </span>
              </p>
              <p className="text-sm">
                Total Borrows:{" "}
                <span className="font-mono">
                  {formatted(poolState?.totalBorrows)} FLOW
                </span>
              </p>
              <p className="text-sm">
                Utilization:{" "}
                <span className="font-mono">
                  {poolState
                    ? (Number.parseFloat(poolState.utilizationRate) * 100).toFixed(2)
                    : "0.00"}
                  %
                </span>
              </p>
            </div>
          </section>

          <section className="w-full max-w-4xl rounded-xl border border-slate-800 bg-slate-900/40 p-4 flex flex-col gap-3">
            <h2 className="font-semibold">Actions</h2>
            <div className="flex flex-wrap items-center gap-3">
              <label className="text-sm flex items-center gap-2">
                Amount (FLOW)
                <input
                  type="text"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                  className="px-2 py-1 text-sm bg-slate-950 border border-slate-700 rounded-md font-mono"
                />
              </label>
            </div>
            <div className="flex flex-wrap gap-2">
              <button
                onClick={handleDeposit}
                className="px-3 py-2 text-xs bg-emerald-500 text-black rounded-lg font-semibold"
              >
                Deposit
              </button>
              <button
                onClick={handleWithdraw}
                className="px-3 py-2 text-xs bg-slate-800 rounded-lg border border-slate-700"
              >
                Withdraw
              </button>
              <button
                onClick={handleBorrow}
                className="px-3 py-2 text-xs bg-orange-500 text-black rounded-lg font-semibold"
              >
                Borrow
              </button>
              <button
                onClick={handleRepay}
                className="px-3 py-2 text-xs bg-slate-700 rounded-lg"
              >
                Repay
              </button>
            </div>
            {txStatus && (
              <p className="text-xs text-slate-400 mt-2 break-all">Tx: {txStatus}</p>
            )}
          </section>
        </>
      )}

      {!isLoggedIn && !loading && (
        <p className="text-sm text-slate-400 mt-10">
          Connect your Flow testnet wallet to manage your FlowLend position.
        </p>
      )}
    </main>
  );
}
