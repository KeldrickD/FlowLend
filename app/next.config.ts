import type { NextConfig } from "next";

const experimentalConfig = {
  turbopack: {
    root: __dirname,
  },
} as NextConfig["experimental"];

const nextConfig: NextConfig = {
  reactCompiler: true,
  experimental: experimentalConfig,
};

export default nextConfig;
