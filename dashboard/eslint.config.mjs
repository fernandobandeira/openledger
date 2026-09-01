import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",

    // The HTTP runtime @hey-api/openapi-ts bundles into its output. It is
    // vendored code, not this app's: it carries four `any`s of its own and it
    // is replaced wholesale on every regeneration, so linting it would report
    // problems no one here can fix. It is not unchecked — `npm run
    // check:api-client` compares it byte for byte against what the spec
    // generates. Ignored NARROWLY on purpose: `src/lib/api/types.gen.ts` and
    // `sdk.gen.ts` are derived from OUR spec and stay linted, so an `any`
    // arriving from crates/api/openapi.json still fails here.
    "src/lib/api/client.gen.ts",
    "src/lib/api/client/**",
    "src/lib/api/core/**",
  ]),
]);

export default eslintConfig;
