// Minimal flat config. `eslint-config-next`'s legacy FlatCompat bridge
// currently throws ("Converting circular structure to JSON") under this
// eslint 9 / Next 16 combination, so this stays intentionally small rather
// than pulling in the Next preset. `lint` is optional tooling here —
// `typecheck`, `test`, and `build` are the scripts that gate P0 acceptance.
export default [
  {
    ignores: [".next/**", "node_modules/**"],
  },
];
