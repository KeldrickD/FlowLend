import FlowToken from "FlowToken"
import FlowLiquidStaking from "FlowLiquidStaking"

/// Redeem sFLOW for underlying FLOW at current exchange rate.
transaction(sAmount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let redeemed <- FlowLiquidStaking.redeemStake(
            sAmount: sAmount,
            user: acct.address
        )

        let vaultRef = acct.storage
            .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow reference to FLOW vault")

        vaultRef.deposit(from: <- redeemed)

        log("Redeemed sFLOW:")
        log(sAmount)
    }

    execute {
        log("Redeem tx completed")
    }
}

