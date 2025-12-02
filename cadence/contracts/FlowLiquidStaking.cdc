import FlowToken from "FlowToken"

access(all) contract FlowLiquidStaking {

    access(all) event DepositedForStake(user: Address, amount: UFix64, sMinted: UFix64)
    access(all) event RedeemedStake(user: Address, sBurned: UFix64, flowReturned: UFix64)

    /// Demo interest rate for staking yield (approx ~5% APR)
    access(all) let interestRatePerSecond: UFix64

    /// Timestamp of last accrual
    access(all) var lastAccrualTimestamp: UFix64

    /// Total FLOW managed by the staking vault
    access(all) var totalStaked: UFix64

    /// Total supply of sFLOW receipts (tracked internally)
    access(all) var sSupply: UFix64

    /// Protocol-owned vault containing all staked FLOW
    access(all) var stakingVault: @FlowToken.Vault

    /// sFLOW balances keyed by user address (off-chain FT illusion)
    access(contract) var sBalances: {Address: UFix64}

    // ---- Yield + accounting helpers ----

    /// Accrue staking yield over time by growing totalStaked
    access(all) fun accrue() {
        let currentTimestamp = getCurrentBlock().timestamp
        let delta: UFix64 = currentTimestamp - self.lastAccrualTimestamp

        if delta <= 0.0 {
            return
        }

        if self.totalStaked > 0.0 {
            let growth: UFix64 = self.totalStaked * self.interestRatePerSecond * delta
            self.totalStaked = self.totalStaked + growth
        }

        self.lastAccrualTimestamp = currentTimestamp
    }

    /// Flow per sFLOW share
    access(all) fun getExchangeRate(): UFix64 {
        if self.sSupply == 0.0 {
            return 1.0
        }
        return self.totalStaked / self.sSupply
    }

    access(all) fun getSBalance(user: Address): UFix64 {
        return self.sBalances[user] ?? 0.0
    }

    // ---- Core actions ----

    /// Stake FLOW and mint sFLOW receipts at the current exchange rate
    access(all) fun depositForStake(from: @FlowToken.Vault, user: Address): UFix64 {
        self.accrue()

        let amount: UFix64 = from.balance
        assert(amount > 0.0, message: "Stake amount must be > 0")

        let rate: UFix64 = self.getExchangeRate()
        let sToMint: UFix64 = amount / rate

        self.stakingVault.deposit(from: <- from)

        self.totalStaked = self.totalStaked + amount
        self.sSupply = self.sSupply + sToMint

        let prev: UFix64 = self.sBalances[user] ?? 0.0
        self.sBalances[user] = prev + sToMint

        emit DepositedForStake(user: user, amount: amount, sMinted: sToMint)

        return sToMint
    }

    /// Redeem sFLOW for the underlying FLOW at current exchange rate
    access(all) fun redeemStake(sAmount: UFix64, user: Address): @FlowToken.Vault {
        self.accrue()

        assert(sAmount > 0.0, message: "Redeem amount must be > 0")

        let userBal: UFix64 = self.sBalances[user] ?? 0.0
        assert(userBal >= sAmount, message: "Insufficient sFLOW balance")

        let rate: UFix64 = self.getExchangeRate()
        let flowReturned: UFix64 = sAmount * rate

        assert(
            flowReturned <= self.stakingVault.balance,
            message: "Not enough FLOW in staking vault to redeem"
        )

        self.sBalances[user] = userBal - sAmount
        self.sSupply = self.sSupply - sAmount
        self.totalStaked = self.totalStaked - flowReturned

        let payout <- self.stakingVault.withdraw(amount: flowReturned) as! @FlowToken.Vault

        emit RedeemedStake(user: user, sBurned: sAmount, flowReturned: flowReturned)

        return <- payout
    }

    init() {
        self.interestRatePerSecond = 0.00000016
        self.lastAccrualTimestamp = getCurrentBlock().timestamp
        self.totalStaked = 0.0
        self.sSupply = 0.0
        self.stakingVault <- FlowToken.createEmptyVault(
            vaultType: Type<@FlowToken.Vault>()
        )
        self.sBalances = {}
    }

}

