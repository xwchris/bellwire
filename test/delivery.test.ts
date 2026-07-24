// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it, vi } from "vitest";

import type {
  BellwireEvent,
  Device,
  EventSchema,
  NotificationSurface,
  Project,
} from "../src/domain/models";
import { InMemoryBellwireRepository } from "../src/repositories/in-memory-bellwire-repository";
import { ApnsClient, ApnsError } from "../src/services/apns-client";
import {
  DeliveryProcessor,
  type ApnsSender,
  type ApnsSenderFactory,
} from "../src/services/delivery-processor";
import { renderNotification } from "../src/services/notification-renderer";

const timestamp = "2026-07-20T10:00:00.000Z";

const project: Project = {
  id: "project-1",
  userId: "user-1",
  name: "Bellwire Store",
  slug: "bellwire-store",
  icon: "bolt.horizontal",
  logoUrl: "https://cdn.example.com/bellwire.png",
  displayOrder: 0,
  category: "commerce",
  status: "active",
  endpoint: "/v1/events/project-1",
  createdAt: timestamp,
  updatedAt: timestamp,
};

const schema: EventSchema = {
  id: "schema-1",
  projectId: project.id,
  eventType: "payment.success",
  fields: {
    amount: { type: "number", required: true },
    secret: { type: "string", sensitive: true },
  },
  version: 1,
  status: "active",
  createdAt: timestamp,
};

const surface: NotificationSurface = {
  id: "surface-1",
  projectId: project.id,
  eventType: schema.eventType,
  type: "notification",
  titleTemplate: "Payment received",
  bodyTemplate: "{{ amount }} complete",
  sound: "default",
  group: "payments",
  priority: "normal",
  enabled: true,
  version: 1,
  createdAt: timestamp,
};

const event: BellwireEvent = {
  id: "event-1",
  projectId: project.id,
  eventType: schema.eventType,
  idempotencyKey: "order-1",
  data: { amount: 1234.5, secret: "never render this" },
  sensitiveFields: ["secret"],
  occurredAt: timestamp,
  receivedAt: timestamp,
  status: "accepted",
};

const device: Device = {
  id: "device-1",
  userId: project.userId,
  installationId: "11111111-1111-4111-8111-111111111111",
  name: "iPhone",
  platform: "ios",
  apnsToken: "a".repeat(64),
  apnsEnvironment: "sandbox",
  appVersion: "1.0",
  lastActiveAt: timestamp,
  pushEnabled: true,
  createdAt: timestamp,
};

async function seededRepository(includeDevice = true) {
  const repository = new InMemoryBellwireRepository();
  await repository.createProject(project);
  await repository.saveEventSchema(schema);
  await repository.saveNotificationSurface(surface);
  await repository.createEventIfAbsent(event);
  if (includeDevice) await repository.saveDevice(device);
  return repository;
}

async function repositoryWithQueuedDelivery(options: {
  project?: Project;
  event?: BellwireEvent;
  schema?: EventSchema | false;
  surface?: NotificationSurface | false;
  device?: Device;
} = {}) {
  const repository = new InMemoryBellwireRepository();
  const selectedProject = options.project ?? project;
  const selectedEvent = options.event ?? event;
  const selectedDevice = options.device ?? device;
  await repository.createProject(selectedProject);
  if (options.schema !== false) await repository.saveEventSchema(options.schema ?? schema);
  if (options.surface !== false) await repository.saveNotificationSurface(options.surface ?? surface);
  await repository.saveDevice(selectedDevice);
  await repository.createEventIfAbsent(selectedEvent);
  await repository.createDeliveryIfAbsent({
    id: `queued-${selectedEvent.id}`,
    eventId: selectedEvent.id,
    deviceId: selectedDevice.id,
    channel: "apns",
    status: "queued",
    attemptCount: 0,
    queuedAt: timestamp,
    updatedAt: timestamp,
  });
  return repository;
}

describe("notification delivery", () => {
  it("renders safe templates without leaking sensitive fields", () => {
    const notification = renderNotification(
      project,
      event,
      {
        ...surface,
        titleTemplate: "{{ secret }}",
        bodyTemplate: "{{ amount }} {{ missing | default: 'complete' }}",
      },
      schema.fields,
    );

    expect(notification.title).toBe("Payment Success");
    expect(notification.body).toBe("1,234.5 complete");
    expect(notification.logoUrl).toBe(project.logoUrl);
    expect(JSON.stringify(notification)).not.toContain("never render this");
  });

  it("does not require APNs credentials until an active device exists", async () => {
    const repository = await seededRepository(false);
    const factory = vi.fn<() => ApnsSender>();

    await new DeliveryProcessor(repository, factory).process(event.id);

    expect(factory).not.toHaveBeenCalled();
    expect(await repository.listDeliveries(event.id)).toEqual([]);
  });

  it("routes each device token to its registered APNs environment", async () => {
    const repository = await seededRepository();
    const send = vi.fn<ApnsSender["send"]>().mockResolvedValue({ providerMessageId: "apns-1" });
    const factory = vi.fn<ApnsSenderFactory>().mockReturnValue({ send });

    await new DeliveryProcessor(repository, factory).process(event.id);

    expect(factory).toHaveBeenCalledWith("sandbox");
    expect(send).toHaveBeenCalledWith(device.apnsToken, expect.any(Object));
    expect(send).toHaveBeenCalledWith(device.apnsToken, expect.objectContaining({
      title: project.name,
      privacyMode: "local_enrichment",
    }));
  });

  it("uses a direct reference for local enrichment without sending rendered detail", async () => {
    const directEvent = {
      ...event,
      data: { directNotificationRef: "payment-ref-1234" },
      sensitiveFields: ["directNotificationRef"],
    };
    const directSchema = {
      ...schema,
      fields: {
        directNotificationRef: { type: "string" as const, required: true, sensitive: true },
      },
    };
    const repository = await repositoryWithQueuedDelivery({
      event: directEvent,
      schema: directSchema,
    });
    const send = vi.fn<ApnsSender["send"]>().mockResolvedValue({});

    await new DeliveryProcessor(repository, { send }).process(directEvent.id);

    expect(send).toHaveBeenCalledWith(device.apnsToken, expect.objectContaining({
      title: project.name,
      privacyMode: "local_enrichment",
      directNotificationRef: "payment-ref-1234",
    }));
  });

  it("renders the configured amount only in hosted detailed mode", async () => {
    const repository = await seededRepository();
    await repository.saveNotificationPreference({
      userId: project.userId,
      mode: "hosted_detailed",
      updatedAt: timestamp,
    });
    const send = vi.fn<ApnsSender["send"]>().mockResolvedValue({});

    await new DeliveryProcessor(repository, { send }).process(event.id);

    expect(send).toHaveBeenCalledWith(device.apnsToken, expect.objectContaining({
      title: "Payment received",
      body: "1,234.5 complete",
      privacyMode: "hosted_detailed",
    }));
  });

  it("does not fall back to an older enabled notification Surface", async () => {
    const repository = await seededRepository();
    await repository.saveNotificationSurface({
      ...surface,
      id: "surface-2",
      enabled: false,
      version: 2,
    });
    const send = vi.fn<ApnsSender["send"]>();

    await new DeliveryProcessor(repository, { send }).process(event.id);

    expect(send).not.toHaveBeenCalled();
    expect(await repository.getNotificationSurface(project.id, event.eventType))
      .toMatchObject({ enabled: false, version: 2 });
    expect(await repository.listNotificationSurfaces(project.id)).toEqual([]);
  });

  it("allows only one concurrent worker to hold a delivery lease", async () => {
    const repository = await seededRepository();
    let releaseSend: (() => void) | undefined;
    let markStarted: (() => void) | undefined;
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    const release = new Promise<void>((resolve) => { releaseSend = resolve; });
    const send = vi.fn<ApnsSender["send"]>(async () => {
      markStarted?.();
      await release;
      return { providerMessageId: "apns-concurrent" };
    });
    const processor = new DeliveryProcessor(repository, { send });

    const first = processor.process(event.id);
    await started;
    await expect(processor.process(event.id)).rejects.toThrow("require retry");
    releaseSend?.();
    await first;

    expect(send).toHaveBeenCalledTimes(1);
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "accepted_by_apns",
      attemptCount: 1,
    }]);
  });

  it("reclaims a queued delivery after a worker interruption and lease timeout", async () => {
    const repository = await seededRepository();
    const queuedAt = "2026-07-20T10:00:00.000Z";
    const initial = await repository.createDeliveryIfAbsent({
      id: "delivery-interrupted",
      eventId: event.id,
      deviceId: device.id,
      channel: "apns",
      status: "queued",
      attemptCount: 0,
      queuedAt,
      updatedAt: queuedAt,
    });
    const interruptedClaim = await repository.claimDelivery(initial.delivery.id, queuedAt, 60, 3);
    expect(interruptedClaim).toMatchObject({ status: "queued", attemptCount: 1 });

    const earlyRetryAt = new Date("2026-07-20T10:00:30.000Z");
    const earlySend = vi.fn<ApnsSender["send"]>();
    await expect(
      new DeliveryProcessor(repository, { send: earlySend }, () => earlyRetryAt, 60).process(event.id),
    ).rejects.toThrow("require retry");
    expect(earlySend).not.toHaveBeenCalled();

    const recoveredAt = new Date("2026-07-20T10:01:01.000Z");
    const send = vi.fn<ApnsSender["send"]>()
      .mockResolvedValue({ providerMessageId: "apns-recovered" });
    await new DeliveryProcessor(repository, { send }, () => recoveredAt, 60).process(event.id);

    expect(send).toHaveBeenCalledTimes(1);
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "accepted_by_apns",
      attemptCount: 2,
      providerMessageId: "apns-recovered",
    }]);
  });

  it("rejects a stale worker result after a newer lease has completed", async () => {
    const repository = await seededRepository();
    const initial = await repository.createDeliveryIfAbsent({
      id: "delivery-stale-worker",
      eventId: event.id,
      deviceId: device.id,
      channel: "apns",
      status: "queued",
      attemptCount: 0,
      queuedAt: timestamp,
      updatedAt: timestamp,
    });
    const firstClaim = await repository.claimDelivery(initial.delivery.id, timestamp, 60, 3);
    const secondClaim = await repository.claimDelivery(
      initial.delivery.id,
      "2026-07-20T10:01:01.000Z",
      60,
      3,
    );
    expect(firstClaim).toMatchObject({ attemptCount: 1 });
    expect(secondClaim).toMatchObject({ attemptCount: 2 });

    await repository.completeClaimedDelivery({
      ...(secondClaim as NonNullable<typeof secondClaim>),
      status: "accepted_by_apns",
      providerMessageId: "new-worker",
      updatedAt: "2026-07-20T10:01:02.000Z",
    });
    const staleResult = await repository.completeClaimedDelivery({
      ...(firstClaim as NonNullable<typeof firstClaim>),
      status: "failed",
      errorCode: "retryable:NetworkError",
      updatedAt: "2026-07-20T10:01:03.000Z",
    });

    expect(staleResult).toBeUndefined();
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "accepted_by_apns",
      attemptCount: 2,
      providerMessageId: "new-worker",
    }]);
  });

  it("does not let a stale QueueUnavailable snapshot overwrite a claimed and completed delivery", async () => {
    const repository = await seededRepository();
    const initial = await repository.createDeliveryIfAbsent({
      id: "delivery-queue-cas",
      eventId: event.id,
      deviceId: device.id,
      channel: "apns",
      status: "queued",
      attemptCount: 0,
      queuedAt: timestamp,
      updatedAt: timestamp,
    });
    const staleSnapshot = initial.delivery;
    const claimed = await repository.claimDelivery(
      staleSnapshot.id,
      "2026-07-20T10:00:01.000Z",
      60,
      3,
    );
    await repository.completeClaimedDelivery({
      ...(claimed as NonNullable<typeof claimed>),
      status: "accepted_by_apns",
      providerMessageId: "accepted-concurrently",
      updatedAt: "2026-07-20T10:00:02.000Z",
    });

    const staleWrite = await repository.recordQueueUnavailable(
      staleSnapshot,
      "2026-07-20T10:00:03.000Z",
      "Queue unavailable",
    );

    expect(staleWrite).toBeUndefined();
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "accepted_by_apns",
      attemptCount: 1,
      providerMessageId: "accepted-concurrently",
    }]);
  });

  it.each([
    {
      name: "a paused project",
      options: { project: { ...project, status: "paused" as const } },
      code: "permanent:ProjectPaused",
    },
    {
      name: "a disabled Surface",
      options: { surface: { ...surface, enabled: false } },
      code: "permanent:SurfaceDisabled",
    },
    {
      name: "a missing schema",
      options: {
        event: { ...event, eventType: "schema.missing" },
        schema: false as const,
        surface: false as const,
      },
      code: "permanent:SchemaMissing",
    },
    {
      name: "a missing Surface",
      options: {
        event: { ...event, eventType: "surface.missing" },
        schema: { ...schema, eventType: "surface.missing" },
        surface: false as const,
      },
      code: "permanent:SurfaceMissing",
    },
    {
      name: "a disabled device",
      options: { device: { ...device, pushEnabled: false } },
      code: "permanent:DeviceDisabled",
    },
  ])("terminally settles a crash-left queued delivery for $name", async ({ options, code }) => {
    const repository = await repositoryWithQueuedDelivery(options);
    const send = vi.fn<ApnsSender["send"]>();
    const selectedEvent = options.event ?? event;

    await new DeliveryProcessor(repository, { send }).process(selectedEvent.id);

    expect(send).not.toHaveBeenCalled();
    expect(await repository.listDeliveries(selectedEvent.id)).toMatchObject([{
      status: "failed",
      attemptCount: 1,
      errorCode: code,
    }]);
  });

  it("retries transient APNs failures and records a later acceptance", async () => {
    const repository = await seededRepository();
    const send = vi.fn<ApnsSender["send"]>()
      .mockRejectedValueOnce(new ApnsError(503, "ServiceUnavailable", true))
      .mockResolvedValueOnce({ providerMessageId: "apns-message-1" });
    const processor = new DeliveryProcessor(repository, { send });

    await expect(processor.process(event.id)).rejects.toThrow("require retry");
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "failed",
      attemptCount: 1,
      errorCode: "retryable:ServiceUnavailable",
    }]);

    await processor.process(event.id);
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "accepted_by_apns",
      attemptCount: 2,
      providerMessageId: "apns-message-1",
    }]);
  });

  it("disables an APNs token after Apple reports it unregistered", async () => {
    const repository = await seededRepository();
    const sender: ApnsSender = {
      send: async () => { throw new ApnsError(410, "Unregistered", false); },
    };

    await new DeliveryProcessor(repository, sender).process(event.id);

    expect(await repository.getDevice(device.id)).toMatchObject({ pushEnabled: false });
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "failed",
      errorCode: "permanent:Unregistered",
    }]);
  });

  it("disables an APNs token when it belongs to a different bundle topic", async () => {
    const repository = await seededRepository();
    const sender: ApnsSender = {
      send: async () => { throw new ApnsError(400, "DeviceTokenNotForTopic", false); },
    };

    await new DeliveryProcessor(repository, sender).process(event.id);

    expect(await repository.getDevice(device.id)).toMatchObject({ pushEnabled: false });
    expect(await repository.listDeliveries(event.id)).toMatchObject([{
      status: "failed",
      errorCode: "permanent:DeviceTokenNotForTopic",
    }]);
  });
});

describe("APNs client", () => {
  it("signs a sandbox alert request with the expected push metadata", async () => {
    let captured: Request | undefined;
    const fetchImpl: typeof fetch = async (input, init) => {
      captured = new Request(input, init);
      return new Response(null, { status: 200, headers: { "apns-id": "provider-123" } });
    };
    const client = new ApnsClient({
      keyId: "KEY123",
      teamId: "TEAM123",
      bundleId: "app.bellwire",
      urlScheme: "bellwire-self-host",
      privateKey: await privateKeyPEM(),
      environment: "sandbox",
    }, fetchImpl);

    const result = await client.send("abc123", {
      title: "Payment received",
      body: "CNY 28",
      sound: "default",
      threadId: "payments",
      priority: "high",
      eventId: "event-123",
      projectId: "project-123",
      logoUrl: "https://cdn.example.com/project.png",
      privacyMode: "hosted_detailed",
    });

    expect(result).toEqual({ providerMessageId: "provider-123" });
    expect(captured?.url).toBe("https://api.sandbox.push.apple.com/3/device/abc123");
    expect(captured?.headers.get("authorization")).toMatch(/^bearer /u);
    expect(captured?.headers.get("apns-topic")).toBe("app.bellwire");
    expect(captured?.headers.get("apns-priority")).toBe("10");
    expect(await captured?.json()).toMatchObject({
      aps: {
        alert: { title: "Payment received", body: "CNY 28" },
        "thread-id": "payments",
        "mutable-content": 1,
      },
      deepLink: "bellwire-self-host://events/event-123",
      projectLogoUrl: "https://cdn.example.com/project.png",
      bellwireNotificationMode: "hosted_detailed",
    });
  });

  it("sends only a localized generic alert plus an opaque direct reference", async () => {
    let captured: Request | undefined;
    const fetchImpl: typeof fetch = async (input, init) => {
      captured = new Request(input, init);
      return new Response(null, { status: 200 });
    };
    const client = new ApnsClient({
      keyId: "KEY123",
      teamId: "TEAM123",
      bundleId: "app.bellwire",
      urlScheme: "bellwire",
      privateKey: await privateKeyPEM(),
      environment: "production",
    }, fetchImpl);

    await client.send("abc123", {
      title: "VideoSays",
      body: "must not cross APNs",
      sound: "default",
      threadId: "payments",
      priority: "normal",
      eventId: "event-123",
      projectId: "project-123",
      privacyMode: "local_enrichment",
      directNotificationRef: "payment-ref-1234",
    });

    const payload = await captured?.json() as Record<string, unknown>;
    expect(payload).toMatchObject({
      aps: {
        alert: {
          title: "VideoSays",
          "loc-key": "BELLWIRE_GENERIC_NOTIFICATION_BODY",
        },
        "mutable-content": 1,
      },
      bellwireNotificationMode: "local_enrichment",
      directNotificationRef: "payment-ref-1234",
    });
    expect(JSON.stringify(payload)).not.toContain("must not cross APNs");
  });
});

async function privateKeyPEM(): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const bytes = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const base64 = btoa(binary).match(/.{1,64}/gu)?.join("\n") ?? "";
  return `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----`;
}
