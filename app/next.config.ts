import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactCompiler: true,
  experimental: {
    turbopack: {
      root: __dirname,
    },
  },
};

export default nextConfig;
