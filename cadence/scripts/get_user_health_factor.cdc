import FlowLend from "FlowLend"

access(all) fun main(user: Address): UFix64 {
    return FlowLend.getUserHealthFactor(user: user)
}

