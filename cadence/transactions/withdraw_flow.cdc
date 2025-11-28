import FlowToken from "FlowToken"
import FlowLend from "FlowLend"

/// Withdraw FLOW collateral back from FlowLend.
transaction(amount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let vaultRef = acct.storage
            .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow reference to FLOW vault")

        let outVault <- FlowLend.withdraw(
            amount: amount,
            user: acct.address
        )

        vaultRef.deposit(from: <- outVault)
    }

    execute {
        log("Withdrew FLOW from FlowLend")
    }
}

