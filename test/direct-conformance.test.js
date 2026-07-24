// SPDX-License-Identifier: AGPL-3.0-only
import { Buffer } from "node:buffer";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { webcrypto } from "node:crypto";
import { URL } from "node:url";

import { afterEach, describe, expect, it, vi } from "vitest";

import { runDirectConformance } from "../skills/bellwire/scripts/conformance-direct.mjs";
import { verifyBellwireDirectRequest } from "../skills/bellwire/scripts/verify-direct-request.mjs";

const reference = "N8Y1uFfPnM6J6q3O2gEmDA";
const connectionId = "conformance-connection";
const deviceKeyId = "11111111-1111-4111-8111-111111111111";
const originalFetch = globalThis.fetch;
const RequestConstructor = globalThis.Request;
const ResponseConstructor = globalThis.Response;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("Direct v2 black-box conformance", () => {
  it("checks every declared endpoint and rejects replay, stale, unknown-key, and tampered requests", async () => {
    const keys = await webcrypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    );
    const privateKey = Buffer.from(
      await webcrypto.subtle.exportKey("pkcs8", keys.privateKey),
    ).toString("base64");
    const publicKey = Buffer.from(
      await webcrypto.subtle.exportKey("raw", keys.publicKey),
    ).toString("base64");
    const consumedNonces = new Set();
    const event = {
      reference,
      eventType: "payment.success",
      title: "Payment received",
      body: "Creator plan renewed",
      subtitle: "Just now",
      occurredAt: "2026-07-25T10:00:00Z",
      data: { amount: "$29.99" },
      deepLink: "https://example.test/orders/1",
      logoUrl: "https://example.test/logo.png",
    };

    globalThis.fetch = vi.fn(async (input, init) => {
      const request = new RequestConstructor(input, init);
      const authorized = await verifyBellwireDirectRequest(request, {
        connectionId,
        keyId: deviceKeyId,
        signingPublicKey: publicKey,
        consumeNonce: async (nonce) => {
          if (consumedNonces.has(nonce)) return false;
          consumedNonces.add(nonce);
          return true;
        },
      });
      if (!authorized) {
        return ResponseConstructor.json({ error: "unauthorized" }, { status: 401 });
      }

      const url = new URL(request.url);
      if (url.pathname === "/bellwire/notification") return ResponseConstructor.json(event);
      if (url.pathname === "/bellwire/inbox") {
        return ResponseConstructor.json({ events: [event], nextCursor: null });
      }
      if (url.pathname === "/bellwire/surfaces") {
        return ResponseConstructor.json({ surfaces: [] });
      }
      return ResponseConstructor.json({ error: "not_found" }, { status: 404 });
    });

    const directory = await mkdtemp(join(tmpdir(), "bellwire-conformance-"));
    try {
      const manifestPath = join(directory, "manifest.json");
      await writeFile(manifestPath, JSON.stringify({
        version: 2,
        connectionId,
        baseUrl: "https://example.test",
        project: {
          id: "22222222-2222-4222-8222-222222222222",
          name: "VideoSays",
          icon: "play.rectangle.fill",
          logoUrl: "https://example.test/logo.png",
          displayOrder: 0,
          category: "commerce",
        },
        endpoints: {
          notification: "/bellwire/notification",
          inbox: "/bellwire/inbox",
          surfaces: "/bellwire/surfaces",
        },
        capabilities: ["notification_detail", "inbox", "surfaces"],
      }));

      await expect(runDirectConformance({
        manifestPath,
        deviceKeyId,
        reference,
        signingPrivateKey: privateKey,
      })).resolves.toEqual({
        protocolVersion: 2,
        connectionId,
        checks: [
          expect.objectContaining({ endpoint: "notification", ok: true }),
          expect.objectContaining({ endpoint: "inbox", ok: true, events: 1 }),
          expect.objectContaining({ endpoint: "surfaces", ok: true, surfaces: 0 }),
          {
            endpoint: "security",
            ok: true,
            cases: ["replayed_nonce", "stale_timestamp", "unknown_key", "tampered_query"],
          },
        ],
      });
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
});
