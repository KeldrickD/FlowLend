import * as fcl from "@onflow/fcl";

const FLOWLEND_ADDRESS = "0xcf265b057b710867";
const FLOW_TOKEN_ADDRESS = "0x7e60df042a9c0868";
const FUNGIBLE_TOKEN_ADDRESS = "0x9a0766d93b6608b7";

const walletConnectProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? null;

const config = fcl
  .config()
  .put("accessNode.api", "https://rest-testnet.onflow.org")
  .put("discovery.wallet", "https://fcl-discovery.onflow.org/testnet/authn")
  .put("app.detail.title", "FlowLend")
  .put("app.detail.icon", "https://avatars.githubusercontent.com/u/0")
  .put("0xFlowLend", FLOWLEND_ADDRESS)
  .put("0xFlowToken", FLOW_TOKEN_ADDRESS)
  .put("0xFungibleToken", FUNGIBLE_TOKEN_ADDRESS);

if (walletConnectProjectId) {
  config.put("fcl.walletConnectV2.projectId", walletConnectProjectId);
} else {
  console.warn(
    "[FlowLend] NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID is not set. WalletConnect wallets may fail to connect."
  );
}

export {};

