import type { NextConfig } from "next";
import path from "path";

const nextConfig: NextConfig = {
  reactCompiler: true,
  experimental: {
    turbo: {
      root: path.join(__dirname),
    },
  },
};

export default nextConfig;
