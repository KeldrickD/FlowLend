import FlowToken from "FlowToken"
import FlowLiquidStaking from "FlowLiquidStaking"

/// Stake FLOW and receive sFLOW receipt balance.
transaction(amount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let vaultRef = acct.storage
            .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow reference to FLOW vault")

        let payment <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault
        let sMinted = FlowLiquidStaking.depositForStake(from: <- payment, user: acct.address)

        log("Staked FLOW:")
        log(amount)
        log("sFLOW minted:")
        log(sMinted)
    }

    execute {
        log("Stake tx completed")
    }
}

