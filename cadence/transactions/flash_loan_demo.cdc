import FlowLend from "FlowLend"

/// Demonstrates borrowing via FlowLend.flashLoan and repaying in the same tx.
transaction(amount: UFix64) {
    prepare(acct: auth(Storage) &Account) {
        let receiver <- FlowLend.createDemoFlashLoanReceiver()

        FlowLend.flashLoan(
            amount: amount,
            receiver: &receiver as &{FlowLend.FlashLoanReceiver},
            initiator: acct.address
        )

        destroy receiver
    }

    execute {
        log("Flash loan demo completed")
    }
}

