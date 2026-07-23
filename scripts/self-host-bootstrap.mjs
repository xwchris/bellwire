#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only

import path from "node:path";

import {
  LOCAL_XCCONFIG_PATH,
  WRANGLER_SELF_HOST_PATH,
  fileExists,
  parseArguments,
  renderLocalXcconfig,
  renderWranglerConfiguration,
  resolveRoot,
  validateBootstrapOptions,
  writeNewFile,
} from "./self-host-config.mjs";

const usage = `Bellwire self-host bootstrap

Usage:
  npm run self-host:bootstrap -- \\
    --team-id ABC123DEFG \\
    --bundle-id com.example.bellwire \\
    --api-url https://bellwire-self-host.example.workers.dev \\
    --supabase-url https://example.supabase.co \\
    --supabase-publishable-key sb_publishable_example

Optional:
  --extension-bundle-id <id>       Defaults to <bundle-id>.NotificationService
  --url-scheme <scheme>            Defaults to the lowercased bundle ID
  --worker-name <name>             Defaults to bellwire-self-host
  --queue-prefix <name>            Defaults to the Worker name
  --apns-environment sandbox|production (default: sandbox)
  --root <path>                    Repository root (default: current directory)
  --json                           Print machine-readable output
  --help
`;

const allowedOptions = new Set([
  "team-id",
  "bundle-id",
  "extension-bundle-id",
  "url-scheme",
  "worker-name",
  "queue-prefix",
  "api-url",
  "supabase-url",
  "supabase-publishable-key",
  "apns-environment",
  "root",
  "json",
  "help",
]);

try {
  const options = parseArguments(process.argv.slice(2), new Set(["help", "json"]), allowedOptions);
  if (options.help) {
    process.stdout.write(usage);
    process.exit(0);
  }

  const root = resolveRoot(options.root);
  const configuration = validateBootstrapOptions(options);
  const iosPath = path.join(root, LOCAL_XCCONFIG_PATH);
  const workerPath = path.join(root, WRANGLER_SELF_HOST_PATH);
  const existing = [];
  if (await fileExists(iosPath)) existing.push(LOCAL_XCCONFIG_PATH);
  if (await fileExists(workerPath)) existing.push(WRANGLER_SELF_HOST_PATH);
  if (existing.length > 0) {
    throw new Error(`Refusing to overwrite existing configuration: ${existing.join(", ")}`);
  }

  await writeNewFile(iosPath, renderLocalXcconfig(configuration));
  await writeNewFile(workerPath, renderWranglerConfiguration(configuration));

  const result = {
    created: [LOCAL_XCCONFIG_PATH, WRANGLER_SELF_HOST_PATH],
    workerName: configuration.workerName,
    deliveryQueue: `${configuration.queuePrefix}-deliveries`,
    deadLetterQueue: `${configuration.queuePrefix}-deliveries-dlq`,
    apnsEnvironment: configuration.apnsEnvironment,
  };
  if (options.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`Created ${LOCAL_XCCONFIG_PATH}\n`);
    process.stdout.write(`Created ${WRANGLER_SELF_HOST_PATH}\n`);
    process.stdout.write("No secrets were written. Add Worker secrets with wrangler, then run npm run self-host:doctor.\n");
  }
} catch (error) {
  process.stderr.write(`Bellwire bootstrap: ${error instanceof Error ? error.message : "Unknown error"}\n`);
  process.stderr.write("Run with --help for usage.\n");
  process.exit(1);
}
