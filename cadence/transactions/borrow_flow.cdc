import FlowToken from "FlowToken"
import FlowLend from "FlowLend"

/// Borrow FLOW against your deposited collateral.
transaction(amount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let vaultRef = acct.storage
            .borrow<&FlowToken.Vault>(from: /storage/flowTokenVault)
            ?? panic("Could not borrow reference to FLOW vault")

        let borrowedVault <- FlowLend.borrow(
            amount: amount,
            user: acct.address
        )

        vaultRef.deposit(from: <- borrowedVault)
    }

    execute {
        log("Borrowed FLOW from FlowLend")
    }
}

