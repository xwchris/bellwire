// SPDX-License-Identifier: AGPL-3.0-only
import type {
  BellwireEvent,
  AgentToken,
  Delivery,
  DeliveryHealth,
  Device,
  DeviceBinding,
  EventListOptions,
  EventListPage,
  EventSchema,
  IngestToken,
  LiveSurface,
  NotificationSurface,
  Project,
} from "../domain/models";
import type {
  BellwireRepository,
  CreateDeliveryResult,
  CreateEventResult,
} from "./bellwire-repository";

function copy<T>(value: T): T {
  return structuredClone(value);
}

export class InMemoryBellwireRepository implements BellwireRepository {
  private readonly projects = new Map<string, Project>();
  private readonly devices = new Map<string, Device>();
  private readonly deviceBindings = new Map<string, DeviceBinding>();
  private readonly agentTokens = new Map<string, AgentToken>();
  private readonly eventSchemas = new Map<string, EventSchema[]>();
  private readonly surfaces = new Map<string, NotificationSurface[]>();
  private readonly liveSurfaces = new Map<string, LiveSurface>();
  private readonly ingestTokens = new Map<string, IngestToken>();
  private readonly events = new Map<string, BellwireEvent>();
  private readonly eventsByIdempotencyKey = new Map<string, string>();
  private readonly deliveries = new Map<string, Delivery>();
  private readonly deliveryByEventDevice = new Map<string, string>();
  private readonly rateLimits = new Map<string, { count: number; startedAt: number }>();
  private readonly appleRefreshTokens = new Map<string, string>();

  async deleteAccount(userId: string): Promise<void> {
    const projectIds = [...this.projects.values()]
      .filter((project) => project.userId === userId)
      .map((project) => project.id);
    for (const projectId of projectIds) await this.deleteProject(projectId);

    for (const [deviceId, device] of this.devices) {
      if (device.userId === userId) this.devices.delete(deviceId);
    }
    for (const [bindingId, binding] of this.deviceBindings) {
      if (binding.userId === userId) this.deviceBindings.delete(bindingId);
    }
    for (const [tokenId, token] of this.agentTokens) {
      if (token.userId === userId) this.agentTokens.delete(tokenId);
    }
    this.appleRefreshTokens.delete(userId);
  }

  async saveAppleRefreshToken(userId: string, encryptedRefreshToken: string): Promise<void> {
    this.appleRefreshTokens.set(userId, encryptedRefreshToken);
  }

  async getAppleRefreshToken(userId: string): Promise<string | undefined> {
    return this.appleRefreshTokens.get(userId);
  }

  async deleteAppleRefreshToken(userId: string): Promise<void> {
    this.appleRefreshTokens.delete(userId);
  }

  async createProject(project: Project): Promise<Project> {
    this.projects.set(project.id, copy(project));
    return copy(project);
  }

  async getProject(projectId: string): Promise<Project | undefined> {
    return this.cloneFrom(this.projects, projectId);
  }

  async listProjects(userId: string): Promise<Project[]> {
    return [...this.projects.values()]
      .filter((project) => project.userId === userId)
      .sort(compareDisplayOrder)
      .map(copy);
  }

  async updateProject(project: Project): Promise<Project> {
    this.projects.set(project.id, copy(project));
    return copy(project);
  }

  async updateProjectDisplayOrder(projectId: string, displayOrder: number): Promise<Project> {
    const project = this.projects.get(projectId);
    if (!project) throw new Error("Project not found");
    const updated = { ...project, displayOrder };
    this.projects.set(projectId, copy(updated));
    return copy(updated);
  }

  async deleteProject(projectId: string): Promise<void> {
    this.projects.delete(projectId);

    for (const key of this.eventSchemas.keys()) {
      if (key.startsWith(`${projectId}:`)) this.eventSchemas.delete(key);
    }
    for (const key of this.surfaces.keys()) {
      if (key.startsWith(`${projectId}:`)) this.surfaces.delete(key);
    }
    for (const [key, surface] of this.liveSurfaces) {
      if (surface.projectId === projectId) this.liveSurfaces.delete(key);
    }
    for (const [tokenId, token] of this.ingestTokens) {
      if (token.projectId === projectId) this.ingestTokens.delete(tokenId);
    }

    const deletedEventIds = new Set<string>();
    for (const [eventId, event] of this.events) {
      if (event.projectId === projectId) {
        deletedEventIds.add(eventId);
        this.events.delete(eventId);
      }
    }
    for (const [key, eventId] of this.eventsByIdempotencyKey) {
      if (deletedEventIds.has(eventId)) this.eventsByIdempotencyKey.delete(key);
    }
    for (const [deliveryId, delivery] of this.deliveries) {
      if (deletedEventIds.has(delivery.eventId)) this.deliveries.delete(deliveryId);
    }
    for (const [key, deliveryId] of this.deliveryByEventDevice) {
      if (!this.deliveries.has(deliveryId)) this.deliveryByEventDevice.delete(key);
    }
  }

  async saveDevice(device: Device): Promise<Device> {
    const existing = [...this.devices.values()].find(
      (candidate) =>
        candidate.apnsToken === device.apnsToken ||
        (candidate.userId === device.userId && candidate.installationId === device.installationId),
    );
    if (existing) {
      const updated = { ...device, id: existing.id, createdAt: existing.createdAt };
      this.devices.set(existing.id, copy(updated));
      return copy(updated);
    }
    this.devices.set(device.id, copy(device));
    return copy(device);
  }

  async getDevice(deviceId: string): Promise<Device | undefined> {
    return this.cloneFrom(this.devices, deviceId);
  }

  async listDevices(userId: string): Promise<Device[]> {
    return [...this.devices.values()]
      .filter((device) => device.userId === userId)
      .sort((left, right) => right.lastActiveAt.localeCompare(left.lastActiveAt))
      .map(copy);
  }

  async deleteDevice(deviceId: string): Promise<void> {
    this.devices.delete(deviceId);
  }

  async saveDeviceBinding(binding: DeviceBinding): Promise<DeviceBinding> {
    this.deviceBindings.set(binding.id, copy(binding));
    return copy(binding);
  }

  async claimDeviceBinding(
    codeHash: string,
    token: Omit<AgentToken, "userId">,
    consumedAt: string,
  ): Promise<AgentToken | undefined> {
    const binding = [...this.deviceBindings.values()].find(
      (candidate) => candidate.codeHash === codeHash,
    );
    if (!binding || binding.consumedAt || Date.parse(binding.expiresAt) <= Date.parse(consumedAt)) {
      return undefined;
    }
    const claimedToken: AgentToken = { ...token, userId: binding.userId };
    const tokenConflict = this.agentTokens.has(claimedToken.id) || [...this.agentTokens.values()]
      .some((candidate) => candidate.tokenHash === claimedToken.tokenHash);
    if (tokenConflict) throw new Error("Agent token conflict");
    this.deviceBindings.set(binding.id, { ...binding, consumedAt });
    this.agentTokens.set(claimedToken.id, copy(claimedToken));
    return copy(claimedToken);
  }

  async saveAgentToken(token: AgentToken): Promise<AgentToken> {
    this.agentTokens.set(token.id, copy(token));
    return copy(token);
  }

  async findAgentTokenByHash(tokenHash: string): Promise<AgentToken | undefined> {
    const now = Date.now();
    const token = [...this.agentTokens.values()].find(
      (candidate) =>
        candidate.tokenHash === tokenHash &&
        !candidate.revokedAt &&
        (!candidate.expiresAt || Date.parse(candidate.expiresAt) > now),
    );
    return token ? copy(token) : undefined;
  }

  async markAgentTokenUsed(tokenId: string, usedAt: string): Promise<void> {
    const token = this.agentTokens.get(tokenId);
    if (token) this.agentTokens.set(tokenId, { ...token, lastUsedAt: usedAt });
  }

  async saveEventSchema(schema: EventSchema): Promise<EventSchema> {
    const key = this.projectTypeKey(schema.projectId, schema.eventType);
    const versions = this.eventSchemas.get(key) ?? [];
    const saved = { ...schema, version: (versions.at(-1)?.version ?? 0) + 1 };
    versions.push(copy(saved));
    this.eventSchemas.set(key, versions);
    return copy(saved);
  }

  async getEventSchema(projectId: string, eventType: string): Promise<EventSchema | undefined> {
    const schema = this.eventSchemas.get(this.projectTypeKey(projectId, eventType))?.at(-1);
    return schema ? copy(schema) : undefined;
  }

  async listEventSchemas(projectId: string): Promise<EventSchema[]> {
    return [...this.eventSchemas.entries()]
      .filter(([key]) => key.startsWith(`${projectId}:`))
      .flatMap(([, versions]) => versions.at(-1) ? [copy(versions.at(-1) as EventSchema)] : []);
  }

  async saveNotificationSurface(surface: NotificationSurface): Promise<NotificationSurface> {
    const key = this.projectTypeKey(surface.projectId, surface.eventType);
    const versions = this.surfaces.get(key) ?? [];
    const saved = { ...surface, version: (versions.at(-1)?.version ?? 0) + 1 };
    versions.push(copy(saved));
    this.surfaces.set(key, versions);
    return copy(saved);
  }

  async getNotificationSurface(
    projectId: string,
    eventType: string,
  ): Promise<NotificationSurface | undefined> {
    const surface = this.surfaces.get(this.projectTypeKey(projectId, eventType))?.at(-1);
    return surface ? copy(surface) : undefined;
  }

  async listNotificationSurfaces(projectId: string): Promise<NotificationSurface[]> {
    return [...this.surfaces.entries()]
      .filter(([key]) => key.startsWith(`${projectId}:`))
      .flatMap(([, versions]) => {
        const latest = versions.at(-1);
        return latest?.enabled ? [copy(latest)] : [];
      });
  }

  async saveLiveSurface(surface: LiveSurface): Promise<LiveSurface> {
    const key = this.projectTypeKey(surface.projectId, surface.surfaceKey);
    const previous = this.liveSurfaces.get(key);
    const saved: LiveSurface = {
      ...surface,
      id: previous?.id ?? surface.id,
      version: (previous?.version ?? 0) + 1,
      createdAt: previous?.createdAt ?? surface.createdAt,
    };
    this.liveSurfaces.set(key, copy(saved));
    return copy(saved);
  }

  async getLiveSurface(projectId: string, surfaceKey: string): Promise<LiveSurface | undefined> {
    return this.cloneFrom(this.liveSurfaces, this.projectTypeKey(projectId, surfaceKey));
  }

  async listLiveSurfaces(projectId: string): Promise<LiveSurface[]> {
    return [...this.liveSurfaces.values()]
      .filter((surface) => surface.projectId === projectId)
      .sort(compareDisplayOrder)
      .map(copy);
  }

  async updateLiveSurfaceDisplayOrder(surfaceId: string, displayOrder: number): Promise<LiveSurface> {
    const entry = [...this.liveSurfaces.entries()].find(([, surface]) => surface.id === surfaceId);
    if (!entry) throw new Error("Live Surface not found");
    const updated = { ...entry[1], displayOrder };
    this.liveSurfaces.set(entry[0], copy(updated));
    return copy(updated);
  }

  async deleteLiveSurface(surfaceId: string): Promise<void> {
    const entry = [...this.liveSurfaces.entries()].find(([, surface]) => surface.id === surfaceId);
    if (entry) this.liveSurfaces.delete(entry[0]);
  }

  async saveIngestToken(token: IngestToken): Promise<IngestToken> {
    this.ingestTokens.set(token.id, copy(token));
    return copy(token);
  }

  async listIngestTokens(projectId: string): Promise<IngestToken[]> {
    return [...this.ingestTokens.values()]
      .filter((token) => token.projectId === projectId)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt))
      .map(copy);
  }

  async findIngestTokenByHash(
    projectId: string,
    tokenHash: string,
  ): Promise<IngestToken | undefined> {
    const now = Date.now();
    const token = [...this.ingestTokens.values()].find(
      (candidate) =>
        candidate.projectId === projectId &&
        candidate.tokenHash === tokenHash &&
        !candidate.revokedAt &&
        (!candidate.expiresAt || Date.parse(candidate.expiresAt) > now),
    );
    return token ? copy(token) : undefined;
  }

  async markIngestTokenUsed(tokenId: string, usedAt: string): Promise<void> {
    const token = this.ingestTokens.get(tokenId);
    if (token) this.ingestTokens.set(tokenId, { ...token, lastUsedAt: usedAt });
  }

  async revokeIngestToken(tokenId: string, revokedAt: string): Promise<void> {
    const token = this.ingestTokens.get(tokenId);
    if (token) this.ingestTokens.set(tokenId, { ...token, revokedAt });
  }

  async consumeRateLimit(key: string, limit: number, windowSeconds: number): Promise<boolean> {
    const now = Date.now();
    const current = this.rateLimits.get(key);
    if (!current || now - current.startedAt >= windowSeconds * 1_000) {
      this.rateLimits.set(key, { count: 1, startedAt: now });
      return true;
    }
    if (current.count >= limit) return false;
    current.count += 1;
    return true;
  }

  async createEventIfAbsent(event: BellwireEvent): Promise<CreateEventResult> {
    const index = this.projectTypeKey(event.projectId, event.idempotencyKey);
    const existingId = this.eventsByIdempotencyKey.get(index);
    const existing = existingId ? this.events.get(existingId) : undefined;
    if (existing) return { event: copy(existing), created: false };
    this.events.set(event.id, copy(event));
    this.eventsByIdempotencyKey.set(index, event.id);
    return { event: copy(event), created: true };
  }

  async listEvents(projectId: string, options: EventListOptions): Promise<EventListPage> {
    let events = [...this.events.values()]
      .filter((event) => event.projectId === projectId)
      .filter((event) => !options.eventType || event.eventType === options.eventType)
      .filter((event) => !options.unreadOnly || !event.readAt)
      .sort((left, right) => right.receivedAt.localeCompare(left.receivedAt));
    if (options.cursor) {
      events = events.filter((event) => event.receivedAt < options.cursor!);
    }
    const page = events.slice(0, options.limit + 1);
    const hasMore = page.length > options.limit;
    const visible = page.slice(0, options.limit).map(copy);
    return {
      events: visible,
      ...(hasMore && visible.at(-1) ? { nextCursor: visible.at(-1)?.receivedAt } : {}),
    };
  }

  async getEvent(eventId: string): Promise<BellwireEvent | undefined> {
    return this.cloneFrom(this.events, eventId);
  }

  async markEventRead(eventId: string, readAt: string): Promise<void> {
    const event = this.events.get(eventId);
    if (event) this.events.set(eventId, { ...event, readAt });
  }

  async markAllEventsRead(projectIds: string[], readAt: string): Promise<number> {
    const ownedProjects = new Set(projectIds);
    let updatedCount = 0;
    for (const [eventId, event] of this.events) {
      if (ownedProjects.has(event.projectId) && !event.readAt) {
        this.events.set(eventId, { ...event, readAt });
        updatedCount += 1;
      }
    }
    return updatedCount;
  }

  async createDeliveryIfAbsent(delivery: Delivery): Promise<CreateDeliveryResult> {
    const index = `${delivery.eventId}:${delivery.deviceId}`;
    const existingId = this.deliveryByEventDevice.get(index);
    const existing = existingId ? this.deliveries.get(existingId) : undefined;
    if (existing) return { delivery: copy(existing), created: false };
    this.deliveries.set(delivery.id, copy(delivery));
    this.deliveryByEventDevice.set(index, delivery.id);
    return { delivery: copy(delivery), created: true };
  }

  async claimDelivery(
    deliveryId: string,
    claimedAt: string,
    leaseSeconds: number,
    maxAttempts: number,
  ): Promise<Delivery | undefined> {
    const delivery = this.deliveries.get(deliveryId);
    if (!delivery || leaseSeconds < 1 || maxAttempts < 1) return undefined;
    const claimTime = Date.parse(claimedAt);
    const leaseExpired = Date.parse(delivery.updatedAt) <= claimTime - leaseSeconds * 1_000;
    if (delivery.status === "queued" && delivery.attemptCount >= maxAttempts && leaseExpired) {
      this.deliveries.set(delivery.id, {
        ...delivery,
        status: "failed",
        errorCode: "permanent:LeaseExpired",
        errorMessage: "Delivery worker lease expired after the maximum number of attempts",
        updatedAt: claimedAt,
      });
      return undefined;
    }
    const claimable = delivery.attemptCount < maxAttempts && (
      (delivery.status === "queued" && (delivery.attemptCount === 0 || leaseExpired)) ||
      (delivery.status === "failed" && delivery.errorCode?.startsWith("retryable:") === true)
    );
    if (!claimable) return undefined;
    const claimed: Delivery = {
      ...delivery,
      status: "queued",
      attemptCount: delivery.attemptCount + 1,
      errorCode: undefined,
      errorMessage: undefined,
      updatedAt: claimedAt,
    };
    this.deliveries.set(claimed.id, copy(claimed));
    return copy(claimed);
  }

  async completeClaimedDelivery(delivery: Delivery): Promise<Delivery | undefined> {
    const current = this.deliveries.get(delivery.id);
    if (
      !current ||
      current.status !== "queued" ||
      current.attemptCount !== delivery.attemptCount
    ) {
      return undefined;
    }
    this.deliveries.set(delivery.id, copy(delivery));
    return copy(delivery);
  }

  async recordQueueUnavailable(
    expected: Delivery,
    failedAt: string,
    message: string,
  ): Promise<Delivery | undefined> {
    const current = this.deliveries.get(expected.id);
    if (
      !current ||
      current.status !== expected.status ||
      current.attemptCount !== expected.attemptCount ||
      current.updatedAt !== expected.updatedAt
    ) {
      return undefined;
    }
    const failed: Delivery = {
      ...current,
      status: "failed",
      errorCode: "retryable:QueueUnavailable",
      errorMessage: message,
      updatedAt: failedAt,
    };
    this.deliveries.set(failed.id, copy(failed));
    return copy(failed);
  }

  async updateDelivery(delivery: Delivery): Promise<Delivery> {
    this.deliveries.set(delivery.id, copy(delivery));
    return copy(delivery);
  }

  async listDeliveries(eventId: string): Promise<Delivery[]> {
    return [...this.deliveries.values()]
      .filter((delivery) => delivery.eventId === eventId)
      .map(copy);
  }

  async getDeliveryHealth(projectId: string): Promise<DeliveryHealth> {
    const eventIds = new Set(
      [...this.events.values()].filter((event) => event.projectId === projectId).map((event) => event.id),
    );
    const deliveries = [...this.deliveries.values()].filter((item) => eventIds.has(item.eventId));
    const queued = deliveries.filter((item) => item.status === "queued").length;
    const accepted = deliveries.filter((item) => item.status === "accepted_by_apns").length;
    const failed = deliveries.filter((item) => item.status === "failed").length;
    return {
      queued,
      accepted,
      failed,
      status: deliveries.length === 0 ? "idle" : failed > 0 ? "degraded" : "healthy",
    };
  }

  private cloneFrom<T>(map: Map<string, T>, key: string): T | undefined {
    const value = map.get(key);
    return value ? copy(value) : undefined;
  }

  private projectTypeKey(projectId: string, value: string): string {
    return `${projectId}:${value}`;
  }
}

function compareDisplayOrder(
  left: { displayOrder: number; id: string },
  right: { displayOrder: number; id: string },
): number {
  return left.displayOrder - right.displayOrder || left.id.localeCompare(right.id);
}
