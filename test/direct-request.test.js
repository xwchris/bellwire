// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from "vitest";
import { Buffer } from "node:buffer";
import { webcrypto } from "node:crypto";
import { TextEncoder } from "node:util";

import { verifyBellwireDirectRequest } from "../skills/bellwire/scripts/verify-direct-request.mjs";

describe("Bellwire Direct request verification", () => {
  it("verifies a device signature and rejects replay", async () => {
    const keys = await webcrypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    );
    const publicKey = Buffer.from(await webcrypto.subtle.exportKey("raw", keys.publicKey))
      .toString("base64");
    const connectionId = "videosays-device-connection";
    const keyId = "11111111-1111-4111-8111-111111111111";
    const timestamp = String(Math.floor(Date.now() / 1_000));
    const nonce = "nonce-for-one-request";
    const canonical = [
      "GET",
      "/api/bellwire/v1/surfaces?period=today",
      timestamp,
      nonce,
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    ].join("\n");
    const signature = Buffer.from(await webcrypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      keys.privateKey,
      new TextEncoder().encode(canonical),
    )).toString("base64");
    const request = new globalThis.Request(
      "https://videosays.com/api/bellwire/v1/surfaces?period=today",
      {
        headers: {
          "x-bellwire-connection": connectionId,
          "x-bellwire-key-id": keyId,
          "x-bellwire-timestamp": timestamp,
          "x-bellwire-nonce": nonce,
          "x-bellwire-signature": signature,
        },
      },
    );
    const consumed = new Set();
    const options = {
      connectionId,
      keyId,
      signingPublicKey: publicKey,
      consumeNonce: async (value) => {
        if (consumed.has(value)) return false;
        consumed.add(value);
        return true;
      },
    };

    await expect(verifyBellwireDirectRequest(request, options)).resolves.toBe(true);
    await expect(verifyBellwireDirectRequest(request, options)).resolves.toBe(false);
    const tampered = new globalThis.Request(request.url.replace("today", "month"), {
      headers: request.headers,
    });
    await expect(verifyBellwireDirectRequest(tampered, {
      ...options,
      consumeNonce: async () => true,
    })).resolves.toBe(false);
  });
});
