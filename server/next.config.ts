import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Route handlers only; no image optimization/remote assets needed for P0.
  reactStrictMode: true,
  // Don't auto-generate AGENTS.md/CLAUDE.md on `next dev` — this repo has its
  // own docs (docs/PLAN.md, docs/API.md) and agent conventions.
  agentRules: false,
};

export default nextConfig;
