import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Opt-in launch audit; excluded from the default P0 regression suite.
export default defineConfig({
  resolve: { alias: { "@": fileURLToPath(new URL("..", import.meta.url)) } },
  test: {
    environment: "node",
    include: ["scripts/commercialization.audit.ts"],
    setupFiles: ["./tests/setup.ts"],
  },
});
