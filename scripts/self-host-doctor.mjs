#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only

import path from "node:path";

import {
  LOCAL_XCCONFIG_PATH,
  WRANGLER_SELF_HOST_PATH,
  containsPlaceholder,
  fileExists,
  parseArguments,
  parseWranglerConfiguration,
  parseXcconfig,
  readText,
  resolveRoot,
  validateBootstrapOptions,
} from "./self-host-config.mjs";

const usage = `Bellwire self-host doctor

Usage:
  npm run self-host:doctor
  npm run self-host:doctor -- --online

Options:
  --online       Verify the Worker health endpoint and Supabase JWKS endpoint
  --root <path>  Repository root (default: current directory)
  --json         Print machine-readable output
  --help
`;

const allowedOptions = new Set(["online", "root", "json", "help"]);

const checks = [];
const errors = [];
const warnings = [];

try {
  const options = parseArguments(
    process.argv.slice(2),
    new Set(["help", "json", "online"]),
    allowedOptions,
  );
  if (options.help) {
    process.stdout.write(usage);
    process.exit(0);
  }

  const root = resolveRoot(options.root);
  const iosPath = path.join(root, LOCAL_XCCONFIG_PATH);
  const workerPath = path.join(root, WRANGLER_SELF_HOST_PATH);
  const iosSource = await requiredFile(iosPath, LOCAL_XCCONFIG_PATH);
  const workerSource = await requiredFile(workerPath, WRANGLER_SELF_HOST_PATH);
  const gitignore = await optionalFile(path.join(root, ".gitignore"));

  if (iosSource && workerSource) {
    rejectSecrets(LOCAL_XCCONFIG_PATH, iosSource);
    rejectSecrets(WRANGLER_SELF_HOST_PATH, workerSource);
    const ios = parseXcconfig(iosSource);
    const worker = parseWranglerConfiguration(workerSource);
    validateRequiredValues(ios, worker);
    validateFormats(ios, worker);
    validateConsistency(ios, worker);
    validateGitignore(gitignore);

    if (options.online && errors.length === 0) {
      await verifyOnline(ios.BELLWIRE_API_BASE_URL, ios.BELLWIRE_SUPABASE_URL);
    }
  }

  const result = { ok: errors.length === 0, checks, warnings, errors };
  if (options.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write("Bellwire self-host doctor\n");
    for (const item of checks) process.stdout.write(`✓ ${item}\n`);
    for (const item of warnings) process.stdout.write(`! ${item}\n`);
    for (const item of errors) process.stdout.write(`✗ ${item}\n`);
    process.stdout.write(result.ok ? "Ready for the next self-hosting step.\n" : "Configuration needs attention.\n");
  }
  process.exit(result.ok ? 0 : 1);
} catch (error) {
  process.stderr.write(`Bellwire doctor: ${error instanceof Error ? error.message : "Unknown error"}\n`);
  process.exit(1);
}

async function requiredFile(filePath, label) {
  if (!(await fileExists(filePath))) {
    errors.push(`${label} is missing; run npm run self-host:bootstrap`);
    return undefined;
  }
  checks.push(`${label} exists`);
  return readText(filePath);
}

async function optionalFile(filePath) {
  return (await fileExists(filePath)) ? readText(filePath) : "";
}

function rejectSecrets(label, source) {
  const secretPatterns = [
    /sb_secret_[A-Za-z0-9_-]+/u,
    /SUPABASE_SERVICE_ROLE_KEY\s*=\s*\S+/u,
    /APNS_PRIVATE_KEY\s*=\s*\S+/u,
    /-----BEGIN (?:EC |RSA )?PRIVATE KEY-----/u,
    /bw_(?:agent|live|ingest)_[A-Za-z0-9_-]{12,}/u,
  ];
  if (secretPatterns.some((pattern) => pattern.test(source))) {
    errors.push(`${label} appears to contain a secret; move it to Wrangler secrets`);
  } else {
    checks.push(`${label} contains no recognized secret values`);
  }
}

function validateRequiredValues(ios, worker) {
  const iosKeys = [
    "BELLWIRE_DEVELOPMENT_TEAM",
    "BELLWIRE_APP_BUNDLE_ID",
    "BELLWIRE_EXTENSION_BUNDLE_ID",
    "BELLWIRE_URL_SCHEME",
    "BELLWIRE_API_BASE_URL",
    "BELLWIRE_SUPABASE_URL",
    "BELLWIRE_SUPABASE_PUBLISHABLE_KEY",
  ];
  const workerKeys = ["APP_ENV", "SUPABASE_URL", "APNS_BUNDLE_ID", "APP_URL_SCHEME", "APNS_ENVIRONMENT"];
  for (const key of iosKeys) validateValue(`iOS ${key}`, ios[key]);
  for (const key of workerKeys) validateValue(`Worker ${key}`, worker.vars[key]);
  validateValue("Worker name", worker.root.name);
  validateValue("delivery Queue", worker.producer.queue);
  validateValue("consumer Queue", worker.consumer.queue);
  validateValue("dead-letter Queue", worker.consumer.dead_letter_queue);
  if (errors.length === 0) checks.push("all required configuration values are resolved");
}

function validateValue(label, value) {
  if (value === undefined || value === "") errors.push(`${label} is missing`);
  else if (containsPlaceholder(value)) errors.push(`${label} still contains an example placeholder`);
}

function validateFormats(ios, worker) {
  const errorCount = errors.length;
  if (errorCount > 0) return;
  try {
    validateBootstrapOptions({
      "team-id": ios.BELLWIRE_DEVELOPMENT_TEAM,
      "bundle-id": ios.BELLWIRE_APP_BUNDLE_ID,
      "extension-bundle-id": ios.BELLWIRE_EXTENSION_BUNDLE_ID,
      "url-scheme": ios.BELLWIRE_URL_SCHEME,
      "worker-name": worker.root.name,
      "queue-prefix": worker.root.name,
      "api-url": ios.BELLWIRE_API_BASE_URL,
      "supabase-url": ios.BELLWIRE_SUPABASE_URL,
      "supabase-publishable-key": ios.BELLWIRE_SUPABASE_PUBLISHABLE_KEY,
      "apns-environment": worker.vars.APNS_ENVIRONMENT,
    });
    checks.push("configuration values use valid formats");
  } catch (error) {
    errors.push(`configuration format is invalid: ${error instanceof Error ? error.message : "Unknown error"}`);
  }
}

function validateConsistency(ios, worker) {
  compare("Bundle ID", ios.BELLWIRE_APP_BUNDLE_ID, worker.vars.APNS_BUNDLE_ID);
  compare("URL scheme", ios.BELLWIRE_URL_SCHEME, worker.vars.APP_URL_SCHEME);
  compare("Supabase URL", normalizeURL(ios.BELLWIRE_SUPABASE_URL), normalizeURL(worker.vars.SUPABASE_URL));
  compare("producer and consumer Queue", worker.producer.queue, worker.consumer.queue);
  const expectedExtension = `${ios.BELLWIRE_APP_BUNDLE_ID}.NotificationService`;
  if (ios.BELLWIRE_EXTENSION_BUNDLE_ID !== expectedExtension) {
    warnings.push(`extension Bundle ID is ${ios.BELLWIRE_EXTENSION_BUNDLE_ID}; expected convention is ${expectedExtension}`);
  } else {
    checks.push("notification extension Bundle ID matches the main App ID");
  }
  if (worker.vars.APP_ENV !== "production") errors.push("Worker APP_ENV must be production for durable self-hosting");
  if (!["sandbox", "production"].includes(worker.vars.APNS_ENVIRONMENT)) {
    errors.push("Worker APNS_ENVIRONMENT must be sandbox or production");
  }
}

function compare(label, left, right) {
  if (left !== right) errors.push(`${label} mismatch between iOS and Worker configuration`);
  else checks.push(`${label} matches between iOS and Worker configuration`);
}

function validateGitignore(source) {
  const ignored = new Set(source.split(/\r?\n/u).map((line) => line.trim()));
  for (const expected of [LOCAL_XCCONFIG_PATH, WRANGLER_SELF_HOST_PATH, ".dev.vars"]) {
    if (ignored.has(expected)) checks.push(`${expected} is ignored by Git`);
    else errors.push(`${expected} is not explicitly ignored by Git`);
  }
}

async function verifyOnline(apiBaseURL, supabaseURL) {
  const health = await fetchJSON(new URL("health", `${normalizeURL(apiBaseURL)}/`), "Worker health");
  if (health?.status !== "ok" || health?.service !== "bellwire-api") {
    errors.push("Worker health endpoint returned an unexpected payload");
  } else if (
    health?.compatibility?.apiVersion !== "v1"
    || typeof health?.compatibility?.appVersion !== "string"
    || typeof health?.compatibility?.schemaMigration !== "string"
  ) {
    errors.push("Worker health endpoint returned incompatible or missing version metadata");
  } else {
    checks.push(
      `Worker is reachable: API ${health.compatibility.apiVersion}, app ${health.compatibility.appVersion}, schema ${health.compatibility.schemaMigration}`,
    );
  }

  const jwks = await fetchJSON(
    new URL("auth/v1/.well-known/jwks.json", `${normalizeURL(supabaseURL)}/`),
    "Supabase JWKS",
  );
  if (!Array.isArray(jwks?.keys)) errors.push("Supabase JWKS endpoint returned an unexpected payload");
  else checks.push("Supabase JWKS endpoint is reachable");
}

async function fetchJSON(url, label) {
  try {
    const response = await fetch(url, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(8_000) });
    if (!response.ok) {
      errors.push(`${label} returned HTTP ${response.status}`);
      return undefined;
    }
    return await response.json();
  } catch (error) {
    errors.push(`${label} failed: ${error instanceof Error ? error.message : "Unknown error"}`);
    return undefined;
  }
}

function normalizeURL(value) {
  try {
    return new URL(value).origin;
  } catch {
    return value;
  }
}
