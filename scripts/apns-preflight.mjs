#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only

import process from "node:process";
import http2 from "node:http2";

import { importPKCS8, SignJWT } from "jose";

import { parseArguments } from "./self-host-config.mjs";

const usage = `Bellwire APNs credential preflight

Reads the APNs .p8 private key from stdin and metadata from environment variables.

Usage:
  APNS_KEY_ID=ABC123DEFG \\
  APNS_TEAM_ID=ABC123DEFG \\
  APNS_BUNDLE_ID=com.example.bellwire \\
  APNS_ENVIRONMENT=sandbox \\
    npm run self-host:apns-preflight < /secure/path/AuthKey_ABC123DEFG.p8

Options:
  --online  Ask APNs to validate the provider token and topic using a dummy device token
  --json    Print machine-readable output
  --help
`;

const acceptedProbeReasons = new Set(["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"]);

try {
  const options = parseArguments(
    process.argv.slice(2),
    new Set(["help", "json", "online"]),
    new Set(["help", "json", "online"]),
  );
  if (options.help) {
    process.stdout.write(usage);
    process.exit(0);
  }

  const keyId = requiredMetadata("APNS_KEY_ID", /^[A-Z0-9]{10}$/u);
  const teamId = requiredMetadata("APNS_TEAM_ID", /^[A-Z0-9]{10}$/u);
  const bundleId = requiredMetadata(
    "APNS_BUNDLE_ID",
    /^(?=.{3,255}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])$/u,
  );
  if (!bundleId.includes(".") || bundleId.includes("..")) {
    throw new Error("APNS_BUNDLE_ID has an invalid format");
  }
  const environment = process.env.APNS_ENVIRONMENT ?? "sandbox";
  if (environment !== "sandbox" && environment !== "production") {
    throw new Error("APNS_ENVIRONMENT must be sandbox or production");
  }

  const privateKey = (await readStdin()).replaceAll("\\n", "\n").trim();
  if (!privateKey.startsWith("-----BEGIN PRIVATE KEY-----")) {
    throw new Error("Pipe the APNs .p8 private key to stdin; it is never persisted or printed");
  }
  const signingKey = await importPKCS8(privateKey, "ES256");
  const providerToken = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(signingKey);

  const result = {
    ok: true,
    key: "valid ES256 PKCS#8",
    providerToken: "generated",
    environment,
    bundleId,
    online: "not requested",
  };

  if (options.online) {
    result.online = await verifyWithAPNs({ providerToken, bundleId, environment });
  }

  if (options.json) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  else {
    process.stdout.write("Bellwire APNs preflight\n");
    process.stdout.write("✓ private key is valid ES256 PKCS#8\n");
    process.stdout.write("✓ provider token was generated without exposing the key\n");
    if (options.online) process.stdout.write("✓ APNs accepted the provider credentials and topic\n");
  }
} catch (error) {
  process.stderr.write(`Bellwire APNs preflight: ${error instanceof Error ? error.message : "Unknown error"}\n`);
  process.exit(1);
}

function requiredMetadata(name, pattern) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  if (!pattern.test(value)) throw new Error(`${name} has an invalid format`);
  return value;
}

async function verifyWithAPNs({ providerToken, bundleId, environment }) {
  const origin = environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const response = await sendHttp2(origin, {
    ":method": "POST",
    ":path": `/3/device/${"0".repeat(64)}`,
    authorization: `bearer ${providerToken}`,
    "apns-topic": bundleId,
    "apns-push-type": "alert",
    "apns-priority": "5",
    "content-type": "application/json",
  }, JSON.stringify({ aps: { alert: "Bellwire credential preflight" } }));
  if (response.status === 200) return "APNs accepted the probe";
  let body = {};
  try {
    body = response.body ? JSON.parse(response.body) : {};
  } catch {
    body = {};
  }
  const reason = typeof body.reason === "string" ? body.reason : `HTTP ${response.status}`;
  if (acceptedProbeReasons.has(reason)) return `credentials accepted; dummy token returned ${reason}`;
  throw new Error(`APNs rejected the credentials or topic: ${reason}`);
}

function sendHttp2(origin, headers, body) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(origin);
    let settled = false;
    const timeout = setTimeout(() => {
      if (settled) return;
      settled = true;
      client.destroy();
      reject(new Error("APNs preflight timed out"));
    }, 10_000);
    const finish = (callback) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      client.close();
      callback();
    };
    client.once("error", (error) => finish(() => reject(error)));
    const request = client.request(headers);
    let status = 0;
    let responseBody = "";
    request.setEncoding("utf8");
    request.on("response", (incomingHeaders) => {
      status = Number(incomingHeaders[":status"] ?? 0);
    });
    request.on("data", (chunk) => { responseBody += chunk; });
    request.once("error", (error) => finish(() => reject(error)));
    request.on("end", () => finish(() => resolve({ status, body: responseBody })));
    request.end(body);
  });
}

async function readStdin() {
  let value = "";
  for await (const chunk of process.stdin) value += chunk;
  return value;
}
