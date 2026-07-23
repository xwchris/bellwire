#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0

import { readFile } from "node:fs/promises";
import process from "node:process";

const [eventFile, idempotencyKey] = process.argv.slice(2);
if (!eventFile || !idempotencyKey) {
  throw new Error("Usage: send-event.mjs <event.json> <stable-idempotency-key>");
}

const apiURL = (process.env.BELLWIRE_API_URL ?? "https://api.bellwire.app").replace(/\/$/u, "");
const projectId = requiredEnvironment("BELLWIRE_PROJECT_ID");
const ingestToken = requiredEnvironment("BELLWIRE_INGEST_TOKEN");
const event = JSON.parse(await readFile(eventFile, "utf8"));
if (
  typeof event.type !== "string"
  || !event.data
  || typeof event.data !== "object"
  || typeof event.occurredAt !== "string"
) {
  throw new Error("Event JSON must contain type, data, and occurredAt");
}

const response = await fetch(`${apiURL}/v1/events/${encodeURIComponent(projectId)}`, {
  method: "POST",
  signal: AbortSignal.timeout(5_000),
  headers: {
    authorization: `Bearer ${ingestToken}`,
    "content-type": "application/json",
    "idempotency-key": idempotencyKey,
  },
  body: JSON.stringify(event),
});
const body = await response.json().catch(() => ({}));
if (!response.ok) {
  const code = body?.error?.code ? `${body.error.code}: ` : "";
  throw new Error(`${code}${body?.error?.message ?? `HTTP ${response.status}`}`);
}

process.stdout.write(`${JSON.stringify({
  eventId: body.eventId,
  deduplicated: body.deduplicated === true,
}, null, 2)}\n`);

function requiredEnvironment(name) {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}
