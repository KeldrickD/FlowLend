import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"
import FlowLend from "FlowLend"

/// Deposit FLOW as collateral into FlowLend.
transaction(amount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let vaultRef = acct.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                from: /storage/flowTokenVault
            )
            ?? panic("Could not borrow reference to FLOW vault")

        let payment <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault

        FlowLend.deposit(
            fromVault: <- payment,
            user: acct.address
        )
    }

    execute {
        log("Deposited FLOW into FlowLend")
    }
}

