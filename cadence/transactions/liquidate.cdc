import FungibleToken from "FungibleToken"
import FlowToken from "FlowToken"
import FlowLend from "FlowLend"

/// Repay part of an undercollateralized borrower's debt and seize collateral + bonus.
transaction(borrower: Address, repayAmount: UFix64) {
    prepare(liquidator: auth(Storage) &Account) {
        let vaultRef = liquidator.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
                from: /storage/flowTokenVault
            )
            ?? panic("Could not borrow reference to FLOW vault")

        let payment <- vaultRef.withdraw(amount: repayAmount) as! @FlowToken.Vault

        let reward <- FlowLend.liquidate(
            borrower: borrower,
            fromVault: <- payment,
            liquidator: liquidator.address
        )

        vaultRef.deposit(from: <- reward)
    }

    execute {
        log("Liquidation executed")
    }
}

