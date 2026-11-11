import { defineConfig } from "oxlint";
import antiSlop from "ultracite/oxlint/anti-slop";
import core from "ultracite/oxlint/core";

export default defineConfig({
  extends: [core, antiSlop],
  ignorePatterns: [...(core.ignorePatterns ?? []), "app/**"],
  options: { reportUnusedDisableDirectives: "error", typeAware: true },
  rules: {
    "eslint/no-redeclare": "off",
    "eslint/prefer-named-capture-group": "off",
    "eslint/sort-keys": "off",
    "unicorn/no-await-expression-member": "off",
  },
});
