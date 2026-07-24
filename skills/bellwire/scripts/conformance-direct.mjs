#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0

import { readFile } from "node:fs/promises";
import { randomBytes, webcrypto } from "node:crypto";
import { pathToFileURL } from "node:url";

const LIMITS = {
  notification: 64 * 1024,
  inbox: 1024 * 1024,
  surfaces: 1024 * 1024,
};

export async function runDirectConformance(options) {
  const manifest = JSON.parse(await readFile(options.manifestPath, "utf8"));
  validateManifest(manifest);
  const privateKey = await importPrivateKey(options.signingPrivateKey);
  const checks = [];
  let securityCandidate;

  if (manifest.capabilities.includes("notification_detail")) {
    if (!options.reference) {
      throw new Error("--reference is required for notification_detail conformance");
    }
    validateReference(options.reference);
    const url = endpointURL(
      manifest,
      "notification",
      new URLSearchParams({ ref: options.reference }),
    );
    const value = await signedJSON(url, manifest.connectionId, options.deviceKeyId, privateKey, LIMITS.notification);
    validatePrivateEvent(value, options.reference);
    securityCandidate = value.request;
    checks.push({ endpoint: "notification", ok: true, bytes: value.bytes });
  }

  if (manifest.capabilities.includes("inbox")) {
    const value = await signedJSON(
      endpointURL(manifest, "inbox", new URLSearchParams({ limit: "50" })),
      manifest.connectionId,
      options.deviceKeyId,
      privateKey,
      LIMITS.inbox,
    );
    if (!Array.isArray(value.json.events) || value.json.events.length > 50) {
      throw new Error("Inbox response must contain at most 50 events");
    }
    for (const event of value.json.events) validatePrivateEvent({ json: event }, event.reference);
    if (value.json.nextCursor !== null && value.json.nextCursor !== undefined) {
      boundedString(value.json.nextCursor, "nextCursor", 1, 512);
    }
    securityCandidate ??= value.request;
    checks.push({ endpoint: "inbox", ok: true, bytes: value.bytes, events: value.json.events.length });
  }

  if (manifest.capabilities.includes("surfaces")) {
    const value = await signedJSON(
      endpointURL(manifest, "surfaces"),
      manifest.connectionId,
      options.deviceKeyId,
      privateKey,
      LIMITS.surfaces,
    );
    if (!Array.isArray(value.json.surfaces)) {
      throw new Error("Surfaces response must contain a surfaces array");
    }
    securityCandidate ??= value.request;
    checks.push({ endpoint: "surfaces", ok: true, bytes: value.bytes, surfaces: value.json.surfaces.length });
  }

  if (!securityCandidate) throw new Error("Manifest must enable at least one supported capability");
  await verifySecurityFailures(
    securityCandidate,
    manifest.connectionId,
    options.deviceKeyId,
    privateKey,
  );
  checks.push({
    endpoint: "security",
    ok: true,
    cases: ["replayed_nonce", "stale_timestamp", "unknown_key", "tampered_query"],
  });

  return { protocolVersion: 2, connectionId: manifest.connectionId, checks };
}

async function signedJSON(url, connectionId, keyId, privateKey, maximumBytes) {
  const request = await signedRequest(url, connectionId, keyId, privateKey);
  const response = await fetch(request.url, {
    headers: request.headers,
    signal: AbortSignal.timeout(8_000),
  });
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > maximumBytes) {
    throw new Error(`${url.pathname} response exceeds ${maximumBytes} bytes`);
  }
  if (!response.ok) throw new Error(`${url.pathname} returned HTTP ${response.status}`);
  let json;
  try {
    json = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new Error(`${url.pathname} did not return valid JSON`);
  }
  if (!isRecord(json)) throw new Error(`${url.pathname} must return a JSON object`);
  return { json, bytes: bytes.byteLength, request };
}

async function signedRequest(
  url,
  connectionId,
  keyId,
  privateKey,
  {
    timestamp = String(Math.floor(Date.now() / 1_000)),
    nonce = randomBytes(24).toString("base64url"),
  } = {},
) {
  const canonical = [
    "GET",
    `${url.pathname}${url.search}`,
    timestamp,
    nonce,
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  ].join("\n");
  const signature = Buffer.from(await webcrypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(canonical),
  )).toString("base64");
  return {
    url,
    headers: {
      accept: "application/json",
      "x-bellwire-connection": connectionId,
      "x-bellwire-key-id": keyId,
      "x-bellwire-timestamp": timestamp,
      "x-bellwire-nonce": nonce,
      "x-bellwire-signature": signature,
    },
  };
}

async function verifySecurityFailures(candidate, connectionId, keyId, privateKey) {
  await expectUnauthorized(candidate.url, candidate.headers, "replayed nonce");

  const stale = await signedRequest(candidate.url, connectionId, keyId, privateKey, {
    timestamp: String(Math.floor(Date.now() / 1_000) - 6 * 60),
  });
  await expectUnauthorized(stale.url, stale.headers, "stale timestamp");

  const unknownKey = await signedRequest(
    candidate.url,
    connectionId,
    `${keyId}-unknown`,
    privateKey,
  );
  await expectUnauthorized(unknownKey.url, unknownKey.headers, "unknown key");

  const signedOriginal = await signedRequest(candidate.url, connectionId, keyId, privateKey);
  const tampered = new URL(signedOriginal.url);
  tampered.searchParams.set("bellwire_conformance_tampered", "1");
  await expectUnauthorized(tampered, signedOriginal.headers, "tampered query");
}

async function expectUnauthorized(url, headers, label) {
  const response = await fetch(url, {
    headers,
    signal: AbortSignal.timeout(8_000),
  });
  await response.body?.cancel();
  if (response.status !== 401) {
    throw new Error(`${label} must return the uniform HTTP 401 response, got ${response.status}`);
  }
}

function validateManifest(value) {
  if (!isRecord(value) || value.version !== 2) throw new Error("Manifest version must be 2");
  boundedString(value.connectionId, "connectionId", 1, 120);
  const base = new URL(value.baseUrl);
  if (base.protocol !== "https:" || base.username || base.password) {
    throw new Error("baseUrl must be HTTPS without embedded credentials");
  }
  if (!isRecord(value.endpoints) || !Array.isArray(value.capabilities)) {
    throw new Error("Manifest endpoints and capabilities are required");
  }
  for (const capability of value.capabilities) {
    if (!["notification_detail", "inbox", "surfaces"].includes(capability)) {
      throw new Error(`Unsupported capability: ${capability}`);
    }
  }
}

function endpointURL(manifest, name, search) {
  const path = manifest.endpoints[name];
  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//")) {
    throw new Error(`endpoints.${name} must be an absolute path`);
  }
  const url = new URL(path, manifest.baseUrl);
  if (url.origin !== new URL(manifest.baseUrl).origin) {
    throw new Error(`endpoints.${name} must remain on baseUrl`);
  }
  if (search) {
    for (const [key, value] of search) url.searchParams.set(key, value);
  }
  return url;
}

function validatePrivateEvent(value, expectedReference) {
  const event = value.json ?? value;
  if (!isRecord(event)) throw new Error("Private event must be a JSON object");
  validateReference(event.reference);
  if (expectedReference && event.reference !== expectedReference) {
    throw new Error("Notification response reference does not match the request");
  }
  boundedString(event.eventType, "eventType", 1, 120);
  boundedString(event.title, "title", 1, 240);
  boundedString(event.body, "body", 1, 1_000);
  if (event.subtitle !== undefined) boundedString(event.subtitle, "subtitle", 0, 240);
  if (typeof event.occurredAt !== "string" || Number.isNaN(Date.parse(event.occurredAt))) {
    throw new Error("occurredAt must be an ISO datetime");
  }
  if (!isRecord(event.data)) throw new Error("data must be a JSON object");
  if (event.deepLink !== undefined && event.deepLink !== null) {
    boundedString(event.deepLink, "deepLink", 1, 2_048);
    const deepLink = new URL(event.deepLink);
    if (!["https:", "bellwire:"].includes(deepLink.protocol)
        || deepLink.username
        || deepLink.password) {
      throw new Error("deepLink must be an HTTPS or bellwire URL without credentials");
    }
  }
  if (event.logoUrl !== undefined && event.logoUrl !== null) {
    boundedString(event.logoUrl, "logoUrl", 1, 2_048);
    const logo = new URL(event.logoUrl);
    if (logo.protocol !== "https:" || logo.username || logo.password || !logo.hostname) {
      throw new Error("logoUrl must be a public HTTPS URL");
    }
  }
}

function validateReference(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{22,200}$/u.test(value)) {
    throw new Error("reference must be a 22-200 character URL-safe opaque value");
  }
}

function boundedString(value, name, minimum, maximum) {
  if (typeof value !== "string" || value.length < minimum || value.length > maximum) {
    throw new Error(`${name} must contain ${minimum}-${maximum} characters`);
  }
}

async function importPrivateKey(encoded) {
  if (!encoded) throw new Error("BELLWIRE_SIGNING_PRIVATE_KEY is required");
  return webcrypto.subtle.importKey(
    "pkcs8",
    Buffer.from(encoded, "base64"),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || !value) throw new Error(`Invalid argument: ${key ?? ""}`);
    result[key.slice(2)] = value;
  }
  return result;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = await runDirectConformance({
      manifestPath: args.manifest,
      deviceKeyId: args["device-key-id"],
      reference: args.reference,
      signingPrivateKey: process.env.BELLWIRE_SIGNING_PRIVATE_KEY,
    });
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`Bellwire conformance: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  }
}
