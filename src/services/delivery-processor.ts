// SPDX-License-Identifier: AGPL-3.0-only
import type {
  Delivery,
  Device,
  EventSchema,
  NotificationSurface,
  Project,
} from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import { ApnsError, type ApnsNotification, type ApnsResult } from "./apns-client";
import { renderNotification } from "./notification-renderer";

export interface ApnsSender {
  send(deviceToken: string, notification: ApnsNotification): Promise<ApnsResult>;
}

export type ApnsSenderFactory = (environment: Device["apnsEnvironment"]) => ApnsSender;

interface DeliveryConfiguration {
  project?: Project;
  schema?: EventSchema;
  surface?: NotificationSurface;
  devices: Map<string, Device>;
  terminalReason?: string;
}

export class DeliveryProcessor {
  constructor(
    private readonly repository: BellwireRepository,
    private readonly apns: ApnsSender | ApnsSenderFactory,
    private readonly now: () => Date = () => new Date(),
    private readonly leaseSeconds = 60,
  ) {}

  async process(eventId: string): Promise<void> {
    const event = await this.repository.getEvent(eventId);
    if (!event) return;

    const [project, existingDeliveries] = await Promise.all([
      this.repository.getProject(event.projectId),
      this.repository.listDeliveries(event.id),
    ]);
    const preflightConfiguration = await this.loadConfiguration(event.eventType, project);
    const deliveries = [...existingDeliveries];

    if (!preflightConfiguration.terminalReason && project) {
      for (const device of preflightConfiguration.devices.values()) {
        if (!device.pushEnabled) continue;
        const now = this.now().toISOString();
        const result = await this.repository.createDeliveryIfAbsent({
          id: crypto.randomUUID(),
          eventId: event.id,
          deviceId: device.id,
          channel: "apns",
          status: "queued",
          attemptCount: 0,
          queuedAt: now,
          updatedAt: now,
        });
        if (!deliveries.some((delivery) => delivery.id === result.delivery.id)) {
          deliveries.push(result.delivery);
        }
      }
    }

    let shouldRetry = false;
    const claims: Delivery[] = [];
    for (const snapshot of deliveries) {
      const delivery = await this.repository.claimDelivery(
        snapshot.id,
        this.now().toISOString(),
        this.leaseSeconds,
        3,
      );
      if (delivery) claims.push(delivery);
      else shouldRetry ||= isPending(snapshot);
    }

    const currentProject = claims.length > 0
      ? await this.repository.getProject(event.projectId)
      : project;
    const configuration = claims.length > 0
      ? await this.loadConfiguration(event.eventType, currentProject)
      : preflightConfiguration;
    const senders = new Map<Device["apnsEnvironment"], ApnsSender>();
    for (const delivery of claims) {
      const device = configuration.devices.get(delivery.deviceId);
      const terminalReason = configuration.terminalReason ?? (
        !device || !device.pushEnabled ? "DeviceDisabled" : undefined
      );
      if (terminalReason) {
        const completed = await this.repository.completeClaimedDelivery({
          ...delivery,
          status: "failed",
          errorCode: `permanent:${terminalReason}`,
          errorMessage: terminalMessage(terminalReason),
          updatedAt: this.now().toISOString(),
        });
        shouldRetry ||= completed === undefined;
        continue;
      }

      const { project: activeProject, schema, surface } = configuration;
      if (!activeProject || !schema || !surface || !device) {
        throw new Error("Delivery configuration invariant failed");
      }
      const sender = typeof this.apns === "function"
        ? senderForEnvironment(senders, device.apnsEnvironment, this.apns)
        : this.apns;
      const eventSensitive = new Set(event.sensitiveFields ?? Object.keys(event.data));
      const fields = Object.fromEntries(
        Object.entries(schema.fields).map(([name, definition]) => [
          name,
          eventSensitive.has(name) ? { ...definition, sensitive: true } : definition,
        ]),
      );
      const notification = renderNotification(activeProject, event, surface, fields);
      try {
        const sent = await sender.send(device.apnsToken, {
          ...notification,
          eventId: event.id,
          projectId: activeProject.id,
        });
        await this.repository.completeClaimedDelivery({
          ...delivery,
          status: "accepted_by_apns",
          providerMessageId: sent.providerMessageId,
          sentAt: this.now().toISOString(),
          updatedAt: this.now().toISOString(),
        });
      } catch (error) {
        const apnsError = error instanceof ApnsError
          ? error
          : new ApnsError(0, "NetworkError", true);
        const retryable = apnsError.retryable && delivery.attemptCount < 3;
        const completed = await this.repository.completeClaimedDelivery({
          ...delivery,
          status: "failed",
          errorCode: `${retryable ? "retryable" : "permanent"}:${apnsError.reason}`,
          errorMessage: apnsError.message.slice(0, 240),
          updatedAt: this.now().toISOString(),
        });
        if (completed && ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(apnsError.reason)) {
          await this.repository.saveDevice({ ...device, pushEnabled: false });
        }
        shouldRetry ||= completed !== undefined && retryable;
      }
    }

    if (shouldRetry) throw new Error("One or more APNs deliveries require retry");
  }

  private async loadConfiguration(
    eventType: string,
    project: Project | undefined,
  ): Promise<DeliveryConfiguration> {
    if (!project) return { devices: new Map(), terminalReason: "ProjectMissing" };
    const [schema, surface, devices] = await Promise.all([
      this.repository.getEventSchema(project.id, eventType),
      this.repository.getNotificationSurface(project.id, eventType),
      this.repository.listDevices(project.userId),
    ]);
    const terminalReason = project.status === "paused"
      ? "ProjectPaused"
      : !schema
        ? "SchemaMissing"
        : !surface
          ? "SurfaceMissing"
          : !surface.enabled
            ? "SurfaceDisabled"
            : undefined;
    return {
      project,
      ...(schema ? { schema } : {}),
      ...(surface ? { surface } : {}),
      devices: new Map(devices.map((device) => [device.id, device])),
      ...(terminalReason ? { terminalReason } : {}),
    };
  }
}

function senderForEnvironment(
  senders: Map<Device["apnsEnvironment"], ApnsSender>,
  environment: Device["apnsEnvironment"],
  factory: ApnsSenderFactory,
): ApnsSender {
  const existing = senders.get(environment);
  if (existing) return existing;
  const sender = factory(environment);
  senders.set(environment, sender);
  return sender;
}

function isPending(delivery: Delivery): boolean {
  return delivery.status === "queued" || (
    delivery.status === "failed" &&
    delivery.errorCode?.startsWith("retryable:") === true &&
    delivery.attemptCount < 3
  );
}

function terminalMessage(reason: string): string {
  const messages: Record<string, string> = {
    ProjectMissing: "Project no longer exists",
    ProjectPaused: "Project is paused",
    SchemaMissing: "Event schema no longer exists",
    SurfaceMissing: "Notification Surface no longer exists",
    SurfaceDisabled: "Notification Surface is disabled",
    DeviceDisabled: "Device push delivery is disabled",
  };
  return messages[reason] ?? "Delivery was cancelled by current configuration";
}
