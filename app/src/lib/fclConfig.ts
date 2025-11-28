import * as fcl from "@onflow/fcl";

declare global {
  interface Window {
    __flowlendWcInitialized?: boolean;
  }
}

const FLOWLEND_ADDRESS = "0xcf265b057b710867";
const FLOW_TOKEN_ADDRESS = "0x7e60df042a9c0868";
const FUNGIBLE_TOKEN_ADDRESS = "0x9a0766d93b6608b7";

const walletConnectProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? null;

const config = fcl
  .config()
  .put("flow.network", "testnet")
  .put("accessNode.api", "https://rest-testnet.onflow.org")
  .put("discovery.wallet", "https://fcl-discovery.onflow.org/testnet/authn")
  .put("discovery.authn.endpoint", "https://rest-testnet.onflow.org/v1/authn")
  .put("discovery.authz.endpoint", "https://rest-testnet.onflow.org/v1/authz")
  .put("app.detail.title", "FlowLend")
  .put("app.detail.icon", "https://flow.com/favicon.ico")
  .put("0xFlowLend", FLOWLEND_ADDRESS)
  .put("0xFlowToken", FLOW_TOKEN_ADDRESS)
  .put("0xFungibleToken", FUNGIBLE_TOKEN_ADDRESS);

if (walletConnectProjectId) {
  config.put("walletconnect.projectId", walletConnectProjectId);

  if (typeof window !== "undefined" && !window.__flowlendWcInitialized) {
    window.__flowlendWcInitialized = true;

    (async () => {
      try {
        const { init } = await import("@onflow/fcl-wc");

        const metadataUrl =
          window.location?.origin ?? "https://flowlend.vercel.app";

        const { FclWcServicePlugin } = await init({
          projectId: walletConnectProjectId,
          metadata: {
            name: "FlowLend",
            description: "Flow-native lending dashboard on testnet",
            url: metadataUrl,
            icons: ["https://flow.com/favicon.ico"],
          },
        });

        fcl.pluginRegistry.add(FclWcServicePlugin);
      } catch (error) {
        console.error(
          "[FlowLend] Failed to initialize WalletConnect plugin",
          error
        );
        window.__flowlendWcInitialized = false;
      }
    })();
  }
} else {
  console.warn(
    "[FlowLend] NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID is not set. WalletConnect wallets may fail to connect."
  );
}

export {};

