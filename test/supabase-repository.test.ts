import { describe, expect, it } from "vitest";

import type {
  AgentToken,
  Delivery,
  Device,
  EventSchema,
  LiveSurface,
  NotificationSurface,
} from "../src/domain/models";
import { SupabaseBellwireRepository } from "../src/repositories/supabase-bellwire-repository";

describe("SupabaseBellwireRepository", () => {
  it("marks unread events across owned projects in one filtered update", async () => {
    let request: Request | undefined;
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([{ id: "event-1" }, { id: "event-2" }]);
      },
    );

    const updated = await repository.markAllEventsRead(
      ["project-1", "project-2"],
      "2026-07-21T14:00:00.000Z",
    );

    expect(updated).toBe(2);
    expect(request?.method).toBe("PATCH");
    const url = new URL(request?.url ?? "https://invalid.example");
    expect(url.searchParams.get("project_id")).toBe("in.(project-1,project-2)");
    expect(url.searchParams.get("read_at")).toBe("is.null");
    expect(url.searchParams.get("select")).toBe("id");
    expect(request?.headers.get("prefer")).toBe("return=representation");
    expect(await request?.json()).toEqual({ read_at: "2026-07-21T14:00:00.000Z" });
  });

  it("lets Postgres preserve a device primary key when an APNs token is re-registered", async () => {
    let request: Request | undefined;
    const storedRow = {
      id: "stored-device-id",
      user_id: "user-1",
      installation_id: "11111111-1111-4111-8111-111111111111",
      name: "Updated iPhone",
      platform: "ios",
      apns_token: "a".repeat(64),
      app_version: "1.1",
      last_active_at: "2026-07-20T12:00:00.000Z",
      push_enabled: true,
      created_at: "2026-07-19T12:00:00.000Z",
    };
    const fetchImpl: typeof fetch = async (input, init) => {
      request = new Request(input, init);
      return Response.json([storedRow]);
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      fetchImpl,
    );
    const input: Device = {
      id: "new-random-id",
      userId: "user-1",
      installationId: "11111111-1111-4111-8111-111111111111",
      name: "Updated iPhone",
      platform: "ios",
      apnsToken: "a".repeat(64),
      appVersion: "1.1",
      lastActiveAt: "2026-07-20T12:00:00.000Z",
      pushEnabled: true,
      createdAt: "2026-07-20T12:00:00.000Z",
    };

    const saved = await repository.saveDevice(input);
    const body = await request?.json();

    expect(body).toMatchObject({
      p_id: input.id,
      p_user_id: input.userId,
      p_installation_id: input.installationId,
      p_apns_token: input.apnsToken,
      p_name: input.name,
    });
    expect(saved).toMatchObject({ id: "stored-device-id", createdAt: storedRow.created_at });
    expect(request?.url).toContain("/rpc/register_device");
  });

  it("saves a live Surface through the atomic version RPC", async () => {
    let request: Request | undefined;
    const storedRow = {
      id: "surface-id",
      project_id: "project-id",
      surface_key: "prod-api",
      type: "metrics",
      title: "API health",
      subtitle: "Production",
      content: { metrics: [{ label: "CPU", value: 18, unit: "%" }] },
      action: null,
      version: 2,
      created_at: "2026-07-21T00:00:00.000Z",
      updated_at: "2026-07-21T00:05:00.000Z",
    };
    const fetchImpl: typeof fetch = async (input, init) => {
      request = new Request(input, init);
      return Response.json([storedRow]);
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      fetchImpl,
    );
    const input: LiveSurface = {
      id: "surface-id",
      projectId: "project-id",
      surfaceKey: "prod-api",
      type: "metrics",
      title: "API health",
      subtitle: "Production",
      content: { metrics: [{ label: "CPU", value: 18, unit: "%" }] },
      version: 2,
      createdAt: "2026-07-21T00:00:00.000Z",
      updatedAt: "2026-07-21T00:05:00.000Z",
    };

    const saved = await repository.saveLiveSurface(input);
    const body = await request?.json();
    expect(request?.url).toBe("https://example.supabase.co/rest/v1/rpc/save_live_surface_version");
    expect(body).toMatchObject({
      p_project_id: "project-id",
      p_surface_key: "prod-api",
      p_content: input.content,
    });
    expect(body).not.toHaveProperty("p_version");
    expect(saved).toMatchObject(input);
  });

  it("saves event schema and notification Surface versions through transaction RPCs", async () => {
    const requests: Request[] = [];
    const schemaRow = {
      id: "schema-id",
      project_id: "project-id",
      event_type: "payment.success",
      fields: { amount: { type: "number" } },
      version: 4,
      status: "active",
      created_at: "2026-07-21T00:00:00.000Z",
    };
    const surfaceRow = {
      id: "surface-id",
      project_id: "project-id",
      event_type: "payment.success",
      type: "notification",
      title_template: "Payment",
      body_template: "Received",
      subtitle_template: null,
      sound: "default",
      group_name: "payment",
      priority: "normal",
      enabled: true,
      version: 5,
      created_at: "2026-07-21T00:01:00.000Z",
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        const request = new Request(input, init);
        requests.push(request);
        return Response.json(request.url.endsWith("save_event_schema_version")
          ? [schemaRow]
          : [surfaceRow]);
      },
    );
    const schema: EventSchema = {
      id: "schema-id",
      projectId: "project-id",
      eventType: "payment.success",
      fields: { amount: { type: "number" } },
      version: 1,
      status: "active",
      createdAt: schemaRow.created_at,
    };
    const surface: NotificationSurface = {
      id: "surface-id",
      projectId: "project-id",
      eventType: "payment.success",
      type: "notification",
      titleTemplate: "Payment",
      bodyTemplate: "Received",
      sound: "default",
      group: "payment",
      priority: "normal",
      enabled: true,
      version: 1,
      createdAt: surfaceRow.created_at,
    };

    const [savedSchema, savedSurface] = await Promise.all([
      repository.saveEventSchema(schema),
      repository.saveNotificationSurface(surface),
    ]);

    expect(requests.map((request) => request.url)).toEqual(expect.arrayContaining([
      "https://example.supabase.co/rest/v1/rpc/save_event_schema_version",
      "https://example.supabase.co/rest/v1/rpc/save_notification_surface_version",
    ]));
    for (const request of requests) expect(await request.json()).not.toHaveProperty("p_version");
    expect(savedSchema.version).toBe(4);
    expect(savedSurface.version).toBe(5);
  });

  it("claims a binding and stores its Agent token through one transactional RPC", async () => {
    let request: Request | undefined;
    const storedRow = {
      id: "token-id",
      user_id: "user-id",
      name: "Codex",
      token_hash: "a".repeat(64),
      scopes: ["project:read"],
      created_at: "2026-07-21T01:00:00.000Z",
      last_used_at: null,
      expires_at: null,
      revoked_at: null,
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([storedRow]);
      },
    );
    const token: Omit<AgentToken, "userId"> = {
      id: "token-id",
      name: "Codex",
      tokenHash: "a".repeat(64),
      scopes: ["project:read"],
      createdAt: "2026-07-21T01:00:00.000Z",
    };

    const claimed = await repository.claimDeviceBinding(
      "b".repeat(64),
      token,
      "2026-07-21T01:00:00.000Z",
    );

    expect(request?.url).toBe("https://example.supabase.co/rest/v1/rpc/claim_device_binding");
    expect(await request?.json()).toMatchObject({
      p_code_hash: "b".repeat(64),
      p_token_id: "token-id",
      p_token_hash: "a".repeat(64),
    });
    expect(claimed).toMatchObject({ id: "token-id", userId: "user-id" });
  });

  it("fetches the latest notification Surface before evaluating enabled", async () => {
    let request: Request | undefined;
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([{
          id: "surface-2",
          project_id: "project-id",
          event_type: "payment.success",
          type: "notification",
          title_template: "Payment",
          body_template: "Received",
          subtitle_template: null,
          sound: "default",
          group_name: "payment",
          priority: "normal",
          enabled: false,
          version: 2,
          created_at: "2026-07-21T01:00:00.000Z",
        }]);
      },
    );

    const latest = await repository.getNotificationSurface("project-id", "payment.success");

    expect(latest).toMatchObject({ enabled: false, version: 2 });
    expect(request?.url).toContain("order=version.desc");
    expect(request?.url).not.toContain("enabled=eq.true");
  });

  it("claims a delivery lease with an atomic repository RPC", async () => {
    let request: Request | undefined;
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([{
          id: "delivery-id",
          event_id: "event-id",
          device_id: "device-id",
          channel: "apns",
          status: "queued",
          attempt_count: 2,
          provider_message_id: null,
          error_code: null,
          error_message: null,
          queued_at: "2026-07-21T01:00:00.000Z",
          sent_at: null,
          updated_at: "2026-07-21T01:02:00.000Z",
        }]);
      },
    );

    const claimed = await repository.claimDelivery(
      "delivery-id",
      "2026-07-21T01:02:00.000Z",
      60,
      3,
    );

    expect(request?.url).toBe("https://example.supabase.co/rest/v1/rpc/claim_delivery");
    expect(await request?.json()).toEqual({
      p_delivery_id: "delivery-id",
      p_claimed_at: "2026-07-21T01:02:00.000Z",
      p_lease_seconds: 60,
      p_max_attempts: 3,
    });
    expect(claimed).toMatchObject({ status: "queued", attemptCount: 2 });
  });

  it("completes a delivery only for the current claimed attempt", async () => {
    let request: Request | undefined;
    const row = {
      id: "delivery-id",
      event_id: "event-id",
      device_id: "device-id",
      channel: "apns",
      status: "accepted_by_apns",
      attempt_count: 2,
      provider_message_id: "apns-id",
      error_code: null,
      error_message: null,
      queued_at: "2026-07-21T01:00:00.000Z",
      sent_at: "2026-07-21T01:02:01.000Z",
      updated_at: "2026-07-21T01:02:01.000Z",
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([row]);
      },
    );

    await repository.completeClaimedDelivery({
      id: "delivery-id",
      eventId: "event-id",
      deviceId: "device-id",
      channel: "apns",
      status: "accepted_by_apns",
      attemptCount: 2,
      providerMessageId: "apns-id",
      queuedAt: "2026-07-21T01:00:00.000Z",
      sentAt: "2026-07-21T01:02:01.000Z",
      updatedAt: "2026-07-21T01:02:01.000Z",
    });

    expect(request?.url).toContain("status=eq.queued");
    expect(request?.url).toContain("attempt_count=eq.2");
    expect(request?.headers.get("prefer")).toBe("return=representation");
  });

  it("records QueueUnavailable through a status, attempt, and timestamp CAS RPC", async () => {
    let request: Request | undefined;
    const expected: Delivery = {
      id: "delivery-id",
      eventId: "event-id",
      deviceId: "device-id",
      channel: "apns",
      status: "queued",
      attemptCount: 0,
      queuedAt: "2026-07-21T01:00:00.000Z",
      updatedAt: "2026-07-21T01:00:00.000Z",
    };
    const repository = new SupabaseBellwireRepository(
      "https://example.supabase.co",
      "service-role-key",
      async (input, init) => {
        request = new Request(input, init);
        return Response.json([]);
      },
    );

    const saved = await repository.recordQueueUnavailable(
      expected,
      "2026-07-21T01:00:01.000Z",
      "Queue unavailable",
    );

    expect(saved).toBeUndefined();
    expect(request?.url).toBe("https://example.supabase.co/rest/v1/rpc/record_queue_unavailable");
    expect(await request?.json()).toEqual({
      p_delivery_id: "delivery-id",
      p_expected_status: "queued",
      p_expected_attempt_count: 0,
      p_expected_updated_at: "2026-07-21T01:00:00.000Z",
      p_failed_at: "2026-07-21T01:00:01.000Z",
      p_error_message: "Queue unavailable",
    });
  });
});
