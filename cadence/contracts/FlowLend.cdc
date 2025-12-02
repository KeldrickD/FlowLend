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

    access(all) event Liquidation(
        borrower: Address,
        liquidator: Address,
        repaidDebt: UFix64,
        collateralSeized: UFix64,
        newBorrowerDebt: UFix64,
        newBorrowerCollateral: UFix64
    )

    access(all) event FlashLoan(
        initiator: Address,
        amount: UFix64
    )

    // ---- Flash loan interface ----

    access(all) resource interface FlashLoanReceiver {
        access(all) fun onFlashLoan(
            borrowed: @FlowToken.Vault,
            amount: UFix64
        ): @FlowToken.Vault
    }

    // ---- Config ----

    /// Max percentage of collateral value that can be borrowed (0.75 = 75% LTV)
    access(all) let collateralFactor: UFix64

    /// If health factor drops below this, position is liquidatable
    access(all) let liquidationThreshold: UFix64

    /// Legacy flat-rate config retained for upgrade compatibility (unused)
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

        let price: UFix64 = self.getFlowPrice()
        assert(price > 0.0, message: "FLOW price must be > 0")

        let collateralValue: UFix64 = collateral * self.collateralFactor * price
        let debtValue: UFix64 = borrowed * price
        return collateralValue / debtValue
    }

    /// Utilization = totalBorrows / totalCollateral
    access(all) fun getUtilization(): UFix64 {
        if self.totalCollateral == 0.0 {
            return 0.0
        }
        return self.totalBorrows / self.totalCollateral
    }

    /// Interest curve parameters (kept as funcs to avoid new stored fields on upgrade).
    access(all) fun getBaseRatePerSecond(): UFix64 {
        return 0.00000005
    }

    access(all) fun getSlope1PerSecond(): UFix64 {
        return 0.00000030
    }

    access(all) fun getSlope2PerSecond(): UFix64 {
        return 0.00000100
    }

    access(all) fun getTargetUtilization(): UFix64 {
        return 0.80
    }

    access(all) fun getLiquidationBonus(): UFix64 {
        return 0.08
    }

    /// Stubbed FLOW price (1.0) so math stays price-aware; swap with oracle later.
    access(all) fun getFlowPrice(): UFix64 {
        return 1.0
    }

    /// Compute borrow rate per second from utilization using a 2-slope model.
    access(all) fun getBorrowRatePerSecond(utilization: UFix64): UFix64 {
        let u: UFix64 = utilization
        let baseRate: UFix64 = self.getBaseRatePerSecond()
        let slope1: UFix64 = self.getSlope1PerSecond()
        let slope2: UFix64 = self.getSlope2PerSecond()
        let target: UFix64 = self.getTargetUtilization()

        if u <= target {
            // Below target: linear ramp from base rate to base + slope1
            return baseRate + (u / target) * slope1
        }

        // Above target: steeper slope (slope2) on the excess utilization
        let excess: UFix64 = (u - target) / (1.0 - target)
        return baseRate + slope1 + (excess * slope2)
    }

    /// Accrue interest on all outstanding borrows based on time passed.
    access(all) fun accrueInterest() {
        let currentTimestamp = getCurrentBlock().timestamp
        let delta: UFix64 = currentTimestamp - self.lastAccrualTimestamp

        if delta <= 0.0 {
            return
        }

        if self.totalBorrows > 0.0 && self.totalCollateral > 0.0 {
            let utilization: UFix64 = self.getUtilization()
            let ratePerSecond: UFix64 = self.getBorrowRatePerSecond(utilization: utilization)

            // Discrete approximation: newDebt = oldDebt * (1 + rate * delta)
            let interestFactor: UFix64 = 1.0 + (ratePerSecond * delta)

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

    /// Liquidate an unhealthy borrower by repaying debt and seizing collateral + bonus.
    access(all) fun liquidate(
        borrower: Address,
        fromVault: @FlowToken.Vault,
        liquidator: Address
    ): @FlowToken.Vault {
        self.accrueInterest()

        let repayAmount: UFix64 = fromVault.balance
        assert(repayAmount > 0.0, message: "Repay amount must be > 0")

        let current = self.readPosition(user: borrower)
        assert(current.borrowed > 0.0, message: "Borrower has no debt")

        let hf: UFix64 = self.computeHealthFactor(
            collateral: current.collateral,
            borrowed: current.borrowed
        )
        assert(
            hf < self.liquidationThreshold,
            message: "Position is not liquidatable"
        )

        assert(
            repayAmount <= current.borrowed,
            message: "Repay amount exceeds borrower debt"
        )

        let liquidationBonus: UFix64 = self.getLiquidationBonus()
        let price: UFix64 = self.getFlowPrice()
        assert(price > 0.0, message: "FLOW price must be > 0")

        // Price-aware calc keeps math oracle-ready even though price = 1.0 for now.
        let repayValue: UFix64 = repayAmount * price
        let collateralValueNeeded: UFix64 = repayValue * (1.0 + liquidationBonus)
        let collateralSeized: UFix64 = collateralValueNeeded / price
        assert(
            current.collateral >= collateralSeized,
            message: "Not enough collateral to seize"
        )

        // Move repayment into protocol liquidity
        self.liquidityVault.deposit(from: <- fromVault)

        assert(
            self.liquidityVault.balance >= collateralSeized,
            message: "Protocol has insufficient liquidity for liquidation payout"
        )

        let updated = PositionInternal(
            collateral: current.collateral - collateralSeized,
            borrowed: current.borrowed - repayAmount
        )
        self.writePosition(user: borrower, position: updated)

        self.totalBorrows = self.totalBorrows - repayAmount
        self.totalCollateral = self.totalCollateral - collateralSeized

        let rewardVault <- self.liquidityVault.withdraw(amount: collateralSeized) as! @FlowToken.Vault

        emit Liquidation(
            borrower: borrower,
            liquidator: liquidator,
            repaidDebt: repayAmount,
            collateralSeized: collateralSeized,
            newBorrowerDebt: updated.borrowed,
            newBorrowerCollateral: updated.collateral
        )

        return <- rewardVault
    }

    /// Execute a flash loan that must be repaid within the same transaction.
    access(all) fun flashLoan(
        amount: UFix64,
        receiver: &{FlashLoanReceiver},
        initiator: Address
    ) {
        self.accrueInterest()

        assert(amount > 0.0, message: "Flash loan amount must be > 0")
        assert(
            self.liquidityVault.balance >= amount,
            message: "Not enough liquidity for flash loan"
        )

        let balanceBefore: UFix64 = self.liquidityVault.balance

        let loan <- self.liquidityVault.withdraw(amount: amount) as! @FlowToken.Vault
        let returned <- receiver.onFlashLoan(
            borrowed: <- loan,
            amount: amount
        )

        self.liquidityVault.deposit(from: <- returned)

        assert(
            self.liquidityVault.balance >= balanceBefore,
            message: "Flash loan was not fully repaid"
        )

        emit FlashLoan(
            initiator: initiator,
            amount: amount
        )
    }

    // ---- Flash loan demo helpers ----

    access(all) resource DemoFlashLoanReceiver: FlashLoanReceiver {
        access(all) fun onFlashLoan(
            borrowed: @FlowToken.Vault,
            amount: UFix64
        ): @FlowToken.Vault {
            log("DemoFlashLoanReceiver: received flash loan of")
            log(amount)
            return <- borrowed
        }

        init() {}
    }

    access(all) fun createDemoFlashLoanReceiver(): @DemoFlashLoanReceiver {
        return <- create DemoFlashLoanReceiver()
    }

    // ---- init / destroy ----

    init() {
        self.positions = {}
        self.totalCollateral = 0.0
        self.totalBorrows = 0.0
        self.collateralFactor = 0.75
        self.liquidationThreshold = 1.05    // must keep HF above 1.05
        // Legacy field retained for upgrade compatibility; dynamic rates use helpers above.
        self.interestRatePerSecond = 0.00000005
        self.lastAccrualTimestamp = getCurrentBlock().timestamp
        self.liquidityVault <- FlowToken.createEmptyVault(
            vaultType: Type<@FlowToken.Vault>()
        )
    }

}


