import FungibleToken from "FungibleToken"

import FlowToken from "FlowToken"

access(all) contract FlowLend {

    // ---- Events ----

    access(all) event Deposit(
        user: Address,
        amount: UFix64,
        newCollateral: UFix64
    )

    access(all) event Withdraw(
        user: Address,
        amount: UFix64,
        newCollateral: UFix64
    )

    access(all) event Borrow(
        user: Address,
        amount: UFix64,
        newDebt: UFix64
    )

    access(all) event Repay(
        user: Address,
        amount: UFix64,
        newDebt: UFix64
    )

    // ---- Config ----

    /// Max percentage of collateral value that can be borrowed (0.75 = 75% LTV)
    access(all) let collateralFactor: UFix64

    /// If health factor drops below this, position is liquidatable (not implemented yet, just tracked)
    access(all) let liquidationThreshold: UFix64

    /// Simple interest rate per second on borrows (e.g. 0.000001 ≈ 0.0001% / sec)
    access(all) let interestRatePerSecond: UFix64

    // ---- State ----

    access(all) struct UserPosition {
        access(all) let collateral: UFix64
        access(all) let borrowed: UFix64
        access(all) let healthFactor: UFix64

        init(collateral: UFix64, borrowed: UFix64, healthFactor: UFix64) {
            self.collateral = collateral
            self.borrowed = borrowed
            self.healthFactor = healthFactor
        }
    }

    access(all) struct PoolState {
        access(all) let totalCollateral: UFix64
        access(all) let totalBorrows: UFix64
        access(all) let utilizationRate: UFix64

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

    access(all) struct PositionInternal {
        access(all) let collateral: UFix64
        access(all) let borrowed: UFix64

        init(collateral: UFix64, borrowed: UFix64) {
            self.collateral = collateral
            self.borrowed = borrowed
        }
    }

    /// User positions mapped by address
    access(contract) var positions: {Address: PositionInternal}

    /// Total collateral and borrows in the system
    access(all) var totalCollateral: UFix64
    access(all) var totalBorrows: UFix64

    /// Global liquidity vault owned by the protocol
    access(all) var liquidityVault: @FlowToken.Vault

    /// Timestamp of last interest accrual
    access(all) var lastAccrualTimestamp: UFix64

    // ---- helpers ----

    access(contract) fun readPosition(user: Address): PositionInternal {
        let maybe = self.positions[user]
        if maybe == nil {
            let zero = PositionInternal(collateral: 0.0, borrowed: 0.0)
            self.positions[user] = zero
            return zero
        }
        return maybe!
    }

    access(contract) fun writePosition(user: Address, position: PositionInternal) {
        self.positions[user] = position
    }

    access(all) fun computeHealthFactor(
        collateral: UFix64,
        borrowed: UFix64
    ): UFix64 {
        if borrowed == 0.0 {
            // Effectively "infinite" health if no debt
            return 9999.0
        }

        let maxBorrowable: UFix64 = collateral * self.collateralFactor
        return maxBorrowable / borrowed
    }

    /// Accrue interest on all outstanding borrows based on time passed.
    access(all) fun accrueInterest() {
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
            var updatedPositions: {Address: PositionInternal} = {}

            for user in self.positions.keys {
                let pos: PositionInternal = self.positions[user]!
                let newBorrowed: UFix64 = pos.borrowed * interestFactor

                updatedPositions[user] = PositionInternal(
                    collateral: pos.collateral,
                    borrowed: newBorrowed
                )
            }

            self.positions = updatedPositions
        }

        self.lastAccrualTimestamp = currentTimestamp
    }

    // ---- Public View Functions ----

    access(all) fun getUserPosition(user: Address): UserPosition {
        let position = self.readPosition(user: user)
        let health = self.computeHealthFactor(
            collateral: position.collateral,
            borrowed: position.borrowed
        )

        return UserPosition(
            collateral: position.collateral,
            borrowed: position.borrowed,
            healthFactor: health
        )
    }

    access(all) fun getUserHealthFactor(user: Address): UFix64 {
        let position = self.readPosition(user: user)
        return self.computeHealthFactor(
            collateral: position.collateral,
            borrowed: position.borrowed
        )
    }

    access(all) fun getPoolState(): PoolState {
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
    access(all) fun deposit(
        fromVault: @FlowToken.Vault,
        user: Address
    ) {
        self.accrueInterest()

        let amount: UFix64 = fromVault.balance
        assert(amount > 0.0, message: "Deposit amount must be > 0")

        // Move tokens into protocol liquidity vault
        self.liquidityVault.deposit(from: <- fromVault)

        // Update position + totals
        let current = self.readPosition(user: user)
        let updated = PositionInternal(
            collateral: current.collateral + amount,
            borrowed: current.borrowed
        )
        self.writePosition(user: user, position: updated)
        self.totalCollateral = self.totalCollateral + amount

        emit Deposit(user: user, amount: amount, newCollateral: updated.collateral)
    }

    /// Withdraw FLOW collateral back to the user, respecting health factor.
    access(all) fun withdraw(
        amount: UFix64,
        user: Address
    ): @FlowToken.Vault {
        self.accrueInterest()

        assert(amount > 0.0, message: "Withdraw amount must be > 0")

        let current = self.readPosition(user: user)

        assert(current.collateral >= amount, message: "Not enough collateral")

        // Simulate new position after withdrawal
        let newCollateral: UFix64 = current.collateral - amount

        let hf: UFix64 = self.computeHealthFactor(
            collateral: newCollateral,
            borrowed: current.borrowed
        )

        if current.borrowed > 0.0 {
            assert(
                hf >= self.liquidationThreshold,
                message: "Withdrawal would make position unhealthy"
            )
        }

        // Update state
        let updated = PositionInternal(
            collateral: newCollateral,
            borrowed: current.borrowed
        )
        self.writePosition(user: user, position: updated)
        self.totalCollateral = self.totalCollateral - amount

        // Send tokens back to user
        let outVault <- self.liquidityVault.withdraw(amount: amount) as! @FlowToken.Vault

        emit Withdraw(user: user, amount: amount, newCollateral: newCollateral)

        return <- outVault
    }

    /// Borrow FLOW from the protocol against your collateral.
    access(all) fun borrow(
        amount: UFix64,
        user: Address
    ): @FlowToken.Vault {
        self.accrueInterest()

        assert(amount > 0.0, message: "Borrow amount must be > 0")

        let current = self.readPosition(user: user)

        // Simulate new position with extra debt
        let newDebt: UFix64 = current.borrowed + amount

        let hf: UFix64 = self.computeHealthFactor(
            collateral: current.collateral,
            borrowed: newDebt
        )

        assert(
            hf >= self.liquidationThreshold,
            message: "Borrow would make position unhealthy"
        )

        assert(
            self.liquidityVault.balance >= amount,
            message: "Not enough liquidity in the pool"
        )

        // Update state
        let updated = PositionInternal(
            collateral: current.collateral,
            borrowed: newDebt
        )
        self.writePosition(user: user, position: updated)
        self.totalBorrows = self.totalBorrows + amount

        // Send FLOW to user
        let outVault <- self.liquidityVault.withdraw(amount: amount) as! @FlowToken.Vault
        emit Borrow(user: user, amount: amount, newDebt: newDebt)

        return <- outVault
    }

    /// Repay borrowed FLOW back into the protocol.
    access(all) fun repay(
        fromVault: @FlowToken.Vault,
        user: Address
    ) {
        self.accrueInterest()

        let amount: UFix64 = fromVault.balance

        assert(amount > 0.0, message: "Repay amount must be > 0")

        let current = self.readPosition(user: user)

        assert(current.borrowed > 0.0, message: "No outstanding debt")

        var repayAmount: UFix64 = amount
        if repayAmount > current.borrowed {
            repayAmount = current.borrowed
        }

        // Move repayment into liquidity vault
        self.liquidityVault.deposit(from: <- fromVault)

        // Update state
        let updated = PositionInternal(
            collateral: current.collateral,
            borrowed: current.borrowed - repayAmount
        )
        self.writePosition(user: user, position: updated)
        self.totalBorrows = self.totalBorrows - repayAmount

        emit Repay(user: user, amount: repayAmount, newDebt: updated.borrowed)
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
        self.liquidityVault <- FlowToken.createEmptyVault(
            vaultType: Type<@FlowToken.Vault>()
        )
    }

}


