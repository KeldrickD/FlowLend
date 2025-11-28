import FungibleToken from "FungibleToken"

import FlowToken from "FlowToken"

pub contract FlowLend {

    // ---- Events ----

    pub event Deposit(
        user: Address,
        amount: UFix64,
        newCollateral: UFix64
    )

    pub event Withdraw(
        user: Address,
        amount: UFix64,
        newCollateral: UFix64
    )

    pub event Borrow(
        user: Address,
        amount: UFix64,
        newDebt: UFix64
    )

    pub event Repay(
        user: Address,
        amount: UFix64,
        newDebt: UFix64
    )

    // ---- Config ----

    /// Max percentage of collateral value that can be borrowed (0.75 = 75% LTV)
    pub let collateralFactor: UFix64

    /// If health factor drops below this, position is liquidatable (not implemented yet, just tracked)
    pub let liquidationThreshold: UFix64

    /// Simple interest rate per second on borrows (e.g. 0.000001 ≈ 0.0001% / sec)
    pub let interestRatePerSecond: UFix64

    // ---- State ----

    pub struct UserPosition {
        pub var collateral: UFix64
        pub var borrowed: UFix64

        init(collateral: UFix64, borrowed: UFix64) {
            self.collateral = collateral
            self.borrowed = borrowed
        }
    }

    pub struct PoolState {
        pub let totalCollateral: UFix64
        pub let totalBorrows: UFix64
        pub let utilizationRate: UFix64

        init(
            totalCollateral: UFix64,
            totalBorrows: UFix64,
            utilizationRate: UFix64
        ) {
            self.totalCollateral = totalCollateral
            self.totalBorrows = totalBorrows
            self.utilizationRate = utilizationRate
        }
    }

    /// User positions mapped by address
    pub var positions: {Address: UserPosition}

    /// Total collateral and borrows in the system
    pub var totalCollateral: UFix64
    pub var totalBorrows: UFix64

    /// Global liquidity vault owned by the protocol
    pub var liquidityVault: @FlowToken.Vault

    /// Timestamp of last interest accrual
    pub var lastAccrualTimestamp: UFix64

    // ---- helpers ----

    pub fun getOrCreatePosition(user: Address): &UserPosition {
        if self.positions[user] == nil {
            self.positions[user] = UserPosition(
                collateral: 0.0,
                borrowed: 0.0
            )
        }
        return &self.positions[user] as &UserPosition
    }

    pub fun computeHealthFactor(position: UserPosition): UFix64 {
        if position.borrowed == 0.0 {
            // Effectively "infinite" health if no debt
            return 9999.0
        }

        let maxBorrowable: UFix64 = position.collateral * self.collateralFactor
        return maxBorrowable / position.borrowed
    }

    /// Accrue interest on all outstanding borrows based on time passed.
    pub fun accrueInterest() {
        let currentTimestamp = getCurrentBlock().timestamp
        let delta: UFix64 = currentTimestamp - self.lastAccrualTimestamp

        if delta <= 0.0 {
            return
        }

        // Simple continuous interest approximation:
        // newDebt = oldDebt * (1 + ratePerSecond * delta)
        let interestFactor: UFix64 = 1.0 + (self.interestRatePerSecond * delta)

        if self.totalBorrows > 0.0 {
            self.totalBorrows = self.totalBorrows * interestFactor

            // Naive approach: scale each user's debt.
            // For a production system you'd use indexes instead.
            var updatedPositions: {Address: UserPosition} = {}

            for user in self.positions.keys {
                let pos: UserPosition = self.positions[user]!
                let newBorrowed: UFix64 = pos.borrowed * interestFactor

                updatedPositions[user] = UserPosition(
                    collateral: pos.collateral,
                    borrowed: newBorrowed
                )
            }

            self.positions = updatedPositions
        }

        self.lastAccrualTimestamp = currentTimestamp
    }

    // ---- Public View Functions ----

    pub fun getUserPosition(user: Address): UserPosition {
        let maybe = self.positions[user]
        if maybe == nil {
            return UserPosition(collateral: 0.0, borrowed: 0.0)
        }
        return maybe!
    }

    pub fun getUserHealthFactor(user: Address): UFix64 {
        let pos = self.getUserPosition(user: user)
        return self.computeHealthFactor(position: pos)
    }

    pub fun getPoolState(): PoolState {
        var utilization: UFix64 = 0.0
        if self.totalCollateral > 0.0 {
            utilization = self.totalBorrows / self.totalCollateral
        }

        return PoolState(
            totalCollateral: self.totalCollateral,
            totalBorrows: self.totalBorrows,
            utilizationRate: utilization
        )
    }

    // ---- Core DeFi Actions ----
    //
    // NOTE: These functions are meant to be called from transactions.
    // Users pass in Vaults / receive Vaults back.

    /// User deposits FLOW as collateral.
    pub fun deposit(
        fromVault: @FlowToken.Vault,
        user: Address
    ) {
        self.accrueInterest()

        let amount: UFix64 = fromVault.balance
        pre {
            amount > 0.0: "Deposit amount must be > 0"
        }

        // Move tokens into protocol liquidity vault
        self.liquidityVault.deposit(from: <- fromVault)

        // Update position + totals
        let posRef = self.getOrCreatePosition(user: user)
        posRef.collateral = posRef.collateral + amount
        self.totalCollateral = self.totalCollateral + amount

        emit Deposit(user: user, amount: amount, newCollateral: posRef.collateral)
    }

    /// Withdraw FLOW collateral back to the user, respecting health factor.
    pub fun withdraw(
        amount: UFix64,
        user: Address
    ): @FlowToken.Vault {
        self.accrueInterest()

        pre {
            amount > 0.0: "Withdraw amount must be > 0"
        }

        let posRef = self.getOrCreatePosition(user: user)

        pre {
            posRef.collateral >= amount: "Not enough collateral"
        }

        // Simulate new position after withdrawal
        let newCollateral: UFix64 = posRef.collateral - amount
        let simulated = UserPosition(
            collateral: newCollateral,
            borrowed: posRef.borrowed
        )

        let hf: UFix64 = self.computeHealthFactor(position: simulated)

        if posRef.borrowed > 0.0 {
            pre {
                hf >= self.liquidationThreshold:
                    "Withdrawal would make position unhealthy"
            }
        }

        // Update state
        posRef.collateral = newCollateral
        self.totalCollateral = self.totalCollateral - amount

        // Send tokens back to user
        let outVault <- self.liquidityVault.withdraw(amount: amount)

        emit Withdraw(user: user, amount: amount, newCollateral: newCollateral)

        return <- outVault
    }

    /// Borrow FLOW from the protocol against your collateral.
    pub fun borrow(
        amount: UFix64,
        user: Address
    ): @FlowToken.Vault {
        self.accrueInterest()

        pre {
            amount > 0.0: "Borrow amount must be > 0"
        }

        let posRef = self.getOrCreatePosition(user: user)

        // Simulate new position with extra debt
        let newDebt: UFix64 = posRef.borrowed + amount
        let simulated = UserPosition(
            collateral: posRef.collateral,
            borrowed: newDebt
        )

        let hf: UFix64 = self.computeHealthFactor(position: simulated)

        pre {
            hf >= self.liquidationThreshold:
                "Borrow would make position unhealthy"
        }

        // Ensure protocol has enough liquidity
        pre {
            self.liquidityVault.balance >= amount:
                "Not enough liquidity in the pool"
        }

        // Update state
        posRef.borrowed = newDebt
        self.totalBorrows = self.totalBorrows + amount

        // Send FLOW to user
        let outVault <- self.liquidityVault.withdraw(amount: amount)
        emit Borrow(user: user, amount: amount, newDebt: newDebt)

        return <- outVault
    }

    /// Repay borrowed FLOW back into the protocol.
    pub fun repay(
        fromVault: @FlowToken.Vault,
        user: Address
    ) {
        self.accrueInterest()

        let amount: UFix64 = fromVault.balance

        pre {
            amount > 0.0: "Repay amount must be > 0"
        }

        let posRef = self.getOrCreatePosition(user: user)

        pre {
            posRef.borrowed > 0.0: "No outstanding debt"
        }

        var repayAmount: UFix64 = amount
        if repayAmount > posRef.borrowed {
            repayAmount = posRef.borrowed
        }

        // Move repayment into liquidity vault
        self.liquidityVault.deposit(from: <- fromVault)

        // Update state
        posRef.borrowed = posRef.borrowed - repayAmount
        self.totalBorrows = self.totalBorrows - repayAmount

        emit Repay(user: user, amount: repayAmount, newDebt: posRef.borrowed)
    }

    // ---- init / destroy ----

    init() {
        self.positions = {}
        self.totalCollateral = 0.0
        self.totalBorrows = 0.0
        self.collateralFactor = 0.75
        self.liquidationThreshold = 1.05    // must keep HF above 1.05
        self.interestRatePerSecond = 0.000001
        self.lastAccrualTimestamp = getCurrentBlock().timestamp
        self.liquidityVault <- FlowToken.createEmptyVault()
    }

    destroy() {
        destroy self.liquidityVault
    }
}


