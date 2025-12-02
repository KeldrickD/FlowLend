import FlowLiquidStaking from "FlowLiquidStaking"

access(all) struct StakingView {
    access(all) let totalStaked: UFix64
    access(all) let sSupply: UFix64
    access(all) let exchangeRate: UFix64
    access(all) let userSBalance: UFix64

    init(
        totalStaked: UFix64,
        sSupply: UFix64,
        exchangeRate: UFix64,
        userSBalance: UFix64
    ) {
        self.totalStaked = totalStaked
        self.sSupply = sSupply
        self.exchangeRate = exchangeRate
        self.userSBalance = userSBalance
    }
}

access(all) fun main(user: Address): StakingView {
    return StakingView(
        totalStaked: FlowLiquidStaking.totalStaked,
        sSupply: FlowLiquidStaking.sSupply,
        exchangeRate: FlowLiquidStaking.getExchangeRate(),
        userSBalance: FlowLiquidStaking.getSBalance(user: user)
    )
}

