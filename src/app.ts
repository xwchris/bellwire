// SPDX-License-Identifier: AGPL-3.0-only
import { Hono, type Context } from "hono";

import { compatibility } from "./compatibility";
import type { AgentScope, Principal } from "./domain/models";
import { AuthenticationError, requireScope, type Authenticator } from "./security/authenticator";
import {
  ServiceError,
  type BellwireService,
  type CreateEventSchemaInput,
  type IngestEventInput,
} from "./services/bellwire-service";

export function createApp(dependencies: {
  service: BellwireService;
  authenticator: Authenticator;
}) {
  const app = new Hono();

  app.get("/health", (context) =>
    context.json({ status: "ok", service: "bellwire-api", compatibility }),
  );

  app.post("/v1/device-bindings", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    return context.json(await dependencies.service.createDeviceBinding(principal), 201);
  });

  app.post("/v1/device-bindings/confirm", async (context) =>
    context.json(
      await dependencies.service.confirmDeviceBinding(
        await readJson(context.req.raw),
        context.req.header("cf-connecting-ip") ?? "unknown",
      ),
      201,
    ),
  );

  app.post("/v1/devices", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    return context.json(
      await dependencies.service.registerDevice(principal, await readJson(context.req.raw)),
      201,
    );
  });

  app.get("/v1/devices", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    return context.json(await dependencies.service.listDevices(principal));
  });

  app.delete("/v1/devices/:deviceId", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    await dependencies.service.deleteDevice(principal, context.req.param("deviceId"));
    return context.body(null, 204);
  });

  app.delete("/v1/account", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    await dependencies.service.deleteAccount(principal);
    return context.body(null, 204);
  });

  app.post("/v1/auth/apple/authorization", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    await dependencies.service.saveAppleAuthorization(principal, await readJson(context.req.raw));
    return context.body(null, 204);
  });

  app.post("/v1/demo", async (context) => {
    const principal = await authenticate(context, dependencies.authenticator);
    const result = await dependencies.service.createDemoExperience(principal);
    return context.json(result, result.created ? 201 : 200);
  });

  app.post("/v1/projects", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    const project = await dependencies.service.createProject(principal, await readJson(context.req.raw));
    return context.json(project, 201);
  });

  app.get("/v1/projects", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(await dependencies.service.listProjects(principal));
  });

  app.get("/v1/projects/:projectId", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(
      await dependencies.service.getProjectOverview(principal, context.req.param("projectId")),
    );
  });

  app.patch("/v1/projects/:projectId", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    return context.json(
      await dependencies.service.updateProject(
        principal,
        context.req.param("projectId"),
        (await readJson(context.req.raw)) as Record<string, unknown>,
      ),
    );
  });

  app.patch("/v1/projects/:projectId/order", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    return context.json(
      await dependencies.service.updateProjectDisplayOrder(
        principal,
        context.req.param("projectId"),
        await readJson(context.req.raw),
      ),
    );
  });

  app.delete("/v1/projects/:projectId", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    await dependencies.service.deleteProject(principal, context.req.param("projectId"));
    return context.body(null, 204);
  });

  app.post("/v1/projects/:projectId/event-schemas", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:write");
    const schema = await dependencies.service.createEventSchema(
      principal,
      context.req.param("projectId"),
      (await readJson(context.req.raw)) as CreateEventSchemaInput,
    );
    return context.json(schema, 201);
  });

  app.post("/v1/projects/:projectId/notification-surfaces", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:write");
    return context.json(
      await dependencies.service.createNotificationSurface(
        principal,
        context.req.param("projectId"),
        (await readJson(context.req.raw)) as Record<string, unknown>,
      ),
      201,
    );
  });

  app.get("/v1/surfaces", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:read");
    return context.json(await dependencies.service.listLiveSurfaces(principal));
  });

  app.get("/v1/projects/:projectId/surfaces", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:read");
    return context.json(
      await dependencies.service.listLiveSurfaces(principal, context.req.param("projectId")),
    );
  });

  app.put("/v1/projects/:projectId/surfaces/:surfaceKey", async (context) => {
    const authorization = context.req.header("authorization");
    if (/^Bearer\s+bw_live_/iu.test(authorization ?? "")) {
      return context.json(
        await dependencies.service.upsertLiveSurfaceFromIngestToken(
          context.req.param("projectId"),
          authorization,
          context.req.param("surfaceKey"),
          await readJson(context.req.raw),
        ),
      );
    }
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:write");
    return context.json(
      await dependencies.service.upsertLiveSurface(
        principal,
        context.req.param("projectId"),
        context.req.param("surfaceKey"),
        await readJson(context.req.raw),
      ),
    );
  });

  app.patch("/v1/projects/:projectId/surfaces/:surfaceKey/order", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:write");
    return context.json(
      await dependencies.service.updateLiveSurfaceDisplayOrder(
        principal,
        context.req.param("projectId"),
        context.req.param("surfaceKey"),
        await readJson(context.req.raw),
      ),
    );
  });

  app.delete("/v1/projects/:projectId/surfaces/:surfaceKey", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "config:write");
    await dependencies.service.deleteLiveSurface(
      principal,
      context.req.param("projectId"),
      context.req.param("surfaceKey"),
    );
    return context.body(null, 204);
  });

  app.post("/v1/projects/:projectId/ingest-tokens", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    const token = await dependencies.service.createIngestToken(
      principal,
      context.req.param("projectId"),
      await readJson(context.req.raw),
    );
    return context.json(token, 201);
  });

  app.delete("/v1/projects/:projectId/ingest-tokens/:tokenId", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:write");
    await dependencies.service.revokeIngestToken(
      principal,
      context.req.param("projectId"),
      context.req.param("tokenId"),
    );
    return context.body(null, 204);
  });

  app.post("/v1/events/:projectId", async (context) => {
    const accepted = await dependencies.service.ingestEvent(
      context.req.param("projectId"),
      context.req.header("authorization"),
      context.req.header("idempotency-key"),
      (await readJson(context.req.raw)) as IngestEventInput,
    );
    return context.json(accepted, accepted.deduplicated ? 200 : 201);
  });

  app.post("/v1/projects/:projectId/events/test", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "event:test");
    return context.json(
      await dependencies.service.sendTestEvent(
        principal,
        context.req.param("projectId"),
        (await readJson(context.req.raw)) as IngestEventInput,
      ),
      201,
    );
  });

  app.get("/v1/projects/:projectId/events", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(
      await dependencies.service.listEvents(principal, context.req.param("projectId"), {
        cursor: readQueryString(context, "cursor"),
        eventType: readQueryString(context, "eventType"),
        limit: readLimit(context),
        unreadOnly: context.req.query("unread") === "true",
      }),
    );
  });

  app.get("/v1/inbox", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(
      await dependencies.service.listInbox(principal, {
        limit: readLimit(context),
        unreadOnly: context.req.query("unread") === "true",
      }),
    );
  });

  app.get("/v1/events/:eventId", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(
      await dependencies.service.getEventDetail(principal, context.req.param("eventId")),
    );
  });

  app.post("/v1/inbox/read-all", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(await dependencies.service.markAllEventsRead(principal));
  });

  app.post("/v1/events/:eventId/read", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "project:read");
    return context.json(
      await dependencies.service.markEventRead(principal, context.req.param("eventId")),
    );
  });

  app.get("/v1/events/:eventId/deliveries", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "delivery:read");
    return context.json(
      await dependencies.service.getDeliveries(principal, context.req.param("eventId")),
    );
  });

  app.get("/v1/projects/:projectId/delivery-health", async (context) => {
    const principal = await scopedPrincipal(context, dependencies.authenticator, "delivery:read");
    return context.json(
      await dependencies.service.getDeliveryHealth(principal, context.req.param("projectId")),
    );
  });

  app.notFound((context) =>
    context.json({ error: { code: "NOT_FOUND", message: "Route not found" } }, 404),
  );

  app.onError((error, context) => {
    if (error instanceof ServiceError || error instanceof AuthenticationError) {
      return context.json(
        {
          error: {
            code: error.code,
            message: error.message,
            ...(error instanceof ServiceError && error.details ? { details: error.details } : {}),
          },
        },
        error.status,
      );
    }
    console.error("Unhandled request error", error instanceof Error ? error.message : "Unknown error");
    return context.json(
      { error: { code: "INTERNAL_ERROR", message: "Internal server error" } },
      500,
    );
  });

  return app;
}

async function authenticate(context: Context, authenticator: Authenticator): Promise<Principal> {
  return authenticator.authenticate(context.req.header("authorization"));
}

async function scopedPrincipal(
  context: Context,
  authenticator: Authenticator,
  scope: AgentScope,
): Promise<Principal> {
  const principal = await authenticate(context, authenticator);
  requireScope(principal, scope);
  return principal;
}

async function readJson(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    throw new ServiceError(400, "INVALID_REQUEST", "A valid JSON body is required");
  }
}

function readQueryString(context: Context, key: string): string | undefined {
  const value = context.req.query(key)?.trim();
  return value ? value : undefined;
}

function readLimit(context: Context): number | undefined {
  const raw = context.req.query("limit");
  if (!raw) return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1) {
    throw new ServiceError(400, "INVALID_REQUEST", "limit must be a positive integer");
  }
  return value;
}
