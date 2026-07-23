// SPDX-License-Identifier: Apache-2.0
import { verifyBellwireDirectRequest } from "../../skills/bellwire/scripts/verify-direct-request.mjs";

interface Env {
  BELLWIRE_CONNECTION_ID: string;
  BELLWIRE_DEVICE_KEY_ID: string;
  BELLWIRE_SIGNING_PUBLIC_KEY: string;
  BELLWIRE_DB: D1Database;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const valid = await verifyBellwireDirectRequest(request, {
      connectionId: env.BELLWIRE_CONNECTION_ID,
      keyId: env.BELLWIRE_DEVICE_KEY_ID,
      signingPublicKey: env.BELLWIRE_SIGNING_PUBLIC_KEY,
      consumeNonce: async (nonce: string) => {
        const result = await env.BELLWIRE_DB
          .prepare("insert or ignore into bellwire_nonces (nonce, expires_at) values (?, ?)")
          .bind(nonce, Math.floor(Date.now() / 1_000) + 600)
          .run();
        return result.meta.changes === 1;
      },
    });
    if (!valid) return Response.json({ error: "unauthorized" }, { status: 401 });

    return Response.json({
      surfaces: [{
        id: "videosays-revenue-today",
        projectId: "videosays-direct",
        surfaceKey: "revenue-today",
        type: "stats",
        title: "Today",
        subtitle: "Private direct connection",
        content: {
          metrics: [{ label: "Revenue", value: "¥128", color: "orange" }],
        },
        action: null,
        displayOrder: 10,
        version: 1,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
        project: {
          id: "videosays-direct",
          name: "VideoSays",
          icon: "play.rectangle.fill",
          logoUrl: "https://videosays.com/logo.png",
        },
      }],
    });
  },
};
