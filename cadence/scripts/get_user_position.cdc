import FlowLend from "FlowLend"

access(all) fun main(user: Address): FlowLend.UserPosition {
    return FlowLend.getUserPosition(user: user)
}

