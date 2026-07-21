import {
  AGENT_SCOPES,
  EVENT_FIELD_TYPES,
  LIVE_SURFACE_TYPES,
  type BellwireEvent,
  type AgentScope,
  type Delivery,
  type EventFieldDefinition,
  type EventFieldType,
  type EventSchema,
  type IngestToken,
  type LiveSurface,
  type LiveSurfaceAction,
  type LiveSurfaceType,
  type NotificationSurface,
  type Principal,
  type Project,
  type ValidationIssue,
} from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import { createOpaqueToken, createPairingCode, hashSecret, readBearerToken } from "../security/tokens";
import type { DeliveryDispatcher } from "./delivery-dispatcher";

type ErrorCode =
  | "INVALID_REQUEST"
  | "PROJECT_NOT_FOUND"
  | "DEVICE_NOT_FOUND"
  | "EVENT_NOT_FOUND"
  | "EVENT_SCHEMA_NOT_FOUND"
  | "NOTIFICATION_SURFACE_NOT_FOUND"
  | "SURFACE_NOT_FOUND"
  | "INVALID_TOKEN"
  | "INVALID_BINDING_CODE"
  | "IDEMPOTENCY_KEY_REQUIRED"
  | "SCHEMA_VALIDATION_FAILED"
  | "PROJECT_PAUSED"
  | "RATE_LIMITED"
  | "FORBIDDEN";

export class ServiceError extends Error {
  constructor(
    readonly status: 400 | 401 | 403 | 404 | 409 | 422 | 429,
    readonly code: ErrorCode,
    message: string,
    readonly details?: ValidationIssue[],
  ) {
    super(message);
    this.name = "ServiceError";
  }
}

export interface CreateEventSchemaInput {
  eventType?: unknown;
  fields?: unknown;
  notification?: unknown;
}

export interface IngestEventInput {
  type?: unknown;
  data?: unknown;
  occurredAt?: unknown;
}

export interface IngestEventResult {
  eventId: string;
  deduplicated: boolean;
  deliveryQueued?: boolean;
}

export interface SurfaceInput {
  eventType?: unknown;
  title?: unknown;
  body?: unknown;
  subtitle?: unknown;
  sound?: unknown;
  group?: unknown;
  priority?: unknown;
  enabled?: unknown;
}

export class BellwireService {
  constructor(
    readonly repository: BellwireRepository,
    private readonly deliveryDispatcher?: DeliveryDispatcher,
  ) {}

  async createProject(principal: Principal, input: unknown): Promise<Project> {
    const body = asRecord(input);
    const name = readNonEmptyString(body.name);
    if (!name) throw invalidRequest("Project name is required");
    const id = crypto.randomUUID();
    const now = new Date().toISOString();
    return this.repository.createProject({
      id,
      userId: principal.userId,
      name,
      slug: `${slugify(name)}-${id.slice(0, 6)}`,
      icon: readNonEmptyString(body.icon) ?? "bolt.horizontal",
      category: readNonEmptyString(body.category) ?? "general",
      status: "active",
      endpoint: `/v1/events/${id}`,
      createdAt: now,
      updatedAt: now,
    });
  }

  async listProjects(principal: Principal): Promise<{ projects: Project[] }> {
    return { projects: await this.repository.listProjects(principal.userId) };
  }

  async getProjectOverview(principal: Principal, projectId: string) {
    const project = await this.requireOwnedProject(principal, projectId);
    const [eventSchemas, notificationSurfaces, liveSurfaces, deliveryHealth] = await Promise.all([
      this.repository.listEventSchemas(projectId),
      this.repository.listNotificationSurfaces(projectId),
      this.repository.listLiveSurfaces(projectId),
      this.repository.getDeliveryHealth(projectId),
    ]);
    return { ...project, eventSchemas, notificationSurfaces, liveSurfaces, deliveryHealth };
  }

  async updateProject(principal: Principal, projectId: string, input: unknown): Promise<Project> {
    const project = await this.requireOwnedProject(principal, projectId);
    const body = asRecord(input);
    const name = body.name === undefined ? project.name : readNonEmptyString(body.name);
    if (!name) throw invalidRequest("Project name must not be empty");
    const status = body.status === undefined ? project.status : body.status;
    if (status !== "active" && status !== "paused") {
      throw invalidRequest("Project status must be active or paused");
    }
    return this.repository.updateProject({
      ...project,
      name,
      status,
      icon: readNonEmptyString(body.icon) ?? project.icon,
      category: readNonEmptyString(body.category) ?? project.category,
      updatedAt: new Date().toISOString(),
    });
  }

  async registerDevice(principal: Principal, input: unknown) {
    const body = asRecord(input);
    const apnsToken = readNonEmptyString(body.apnsToken);
    const name = readNonEmptyString(body.name);
    if (!name) throw invalidRequest("Device name is required");
    if (!apnsToken || !/^[A-Fa-f0-9]{32,256}$/u.test(apnsToken)) {
      throw invalidRequest("A valid APNs device token is required");
    }
    const now = new Date().toISOString();
    return this.repository.saveDevice({
      id: crypto.randomUUID(),
      userId: principal.userId,
      name,
      platform: "ios",
      apnsToken: apnsToken.toLowerCase(),
      appVersion: readNonEmptyString(body.appVersion),
      lastActiveAt: now,
      pushEnabled: body.pushEnabled !== false,
      createdAt: now,
    });
  }

  async listDevices(principal: Principal) {
    return { devices: await this.repository.listDevices(principal.userId) };
  }

  async deleteDevice(principal: Principal, deviceId: string): Promise<void> {
    const device = await this.repository.getDevice(deviceId);
    if (!device || device.userId !== principal.userId) {
      throw new ServiceError(404, "DEVICE_NOT_FOUND", "Device not found");
    }
    await this.repository.deleteDevice(deviceId);
  }

  async createDeviceBinding(principal: Principal) {
    const code = createPairingCode();
    const now = new Date();
    const expiresAt = new Date(now.getTime() + 10 * 60 * 1_000).toISOString();
    await this.repository.saveDeviceBinding({
      id: crypto.randomUUID(),
      userId: principal.userId,
      codeHash: await hashSecret(code),
      expiresAt,
      createdAt: now.toISOString(),
    });
    return { code, expiresAt };
  }

  async confirmDeviceBinding(input: unknown, clientIp = "unknown") {
    const body = asRecord(input);
    const code = readNonEmptyString(body.code);
    if (!code || !/^\d{6}$/u.test(code)) throw invalidBindingCode();
    const name = body.name === undefined ? "Codex" : readBoundedString(body.name, "Agent name", 80);
    const codeHash = await hashSecret(code);
    const ipHash = await hashSecret(clientIp);
    const [ipAllowed, codeAllowed] = await Promise.all([
      this.repository.consumeRateLimit(`binding-confirm:ip:${ipHash}`, 20, 10 * 60),
      this.repository.consumeRateLimit(`binding-confirm:code:${codeHash}`, 5, 10 * 60),
    ]);
    if (!ipAllowed || !codeAllowed) {
      throw new ServiceError(429, "RATE_LIMITED", "Binding confirmation rate limit exceeded");
    }
    const token = createOpaqueToken("agent");
    const now = new Date().toISOString();
    const record = await this.repository.claimDeviceBinding(codeHash, {
      id: crypto.randomUUID(),
      name,
      tokenHash: await hashSecret(token),
      scopes: [...AGENT_SCOPES],
      createdAt: now,
    }, now);
    if (!record) throw invalidBindingCode();
    return {
      id: record.id,
      name: record.name,
      scopes: record.scopes,
      token,
      createdAt: record.createdAt,
    };
  }

  async createEventSchema(
    principal: Principal,
    projectId: string,
    input: CreateEventSchemaInput,
  ): Promise<EventSchema> {
    const project = await this.requireOwnedProject(principal, projectId);
    const eventType = parseEventType(input.eventType);
    const fields = parseFields(input.fields);
    const schema: EventSchema = {
      id: crypto.randomUUID(),
      projectId,
      eventType,
      fields,
      version: 1,
      status: "active",
      createdAt: new Date().toISOString(),
    };
    const saved = await this.repository.saveEventSchema(schema);
    if (input.notification !== undefined) {
      const notification = asRecord(input.notification);
      await this.createNotificationSurface(principal, projectId, {
        ...notification,
        eventType,
      });
    } else if (saved.version === 1) {
      await this.createDefaultSurface(project, saved);
    }
    return saved;
  }

  async createNotificationSurface(
    principal: Principal,
    projectId: string,
    input: SurfaceInput,
  ): Promise<NotificationSurface> {
    await this.requireOwnedProject(principal, projectId);
    const eventType = parseEventType(input.eventType);
    const schema = await this.repository.getEventSchema(projectId, eventType);
    if (!schema) {
      throw new ServiceError(404, "EVENT_SCHEMA_NOT_FOUND", "Event schema not found");
    }
    const title = readNonEmptyString(input.title);
    const body = readNonEmptyString(input.body);
    if (!title || !body) throw invalidRequest("Notification title and body are required");
    validateTemplate(title, schema.fields, "title");
    validateTemplate(body, schema.fields, "body");
    const subtitle = readNonEmptyString(input.subtitle);
    if (subtitle) validateTemplate(subtitle, schema.fields, "subtitle");
    const priority = input.priority === undefined ? "normal" : input.priority;
    if (priority !== "normal" && priority !== "high") {
      throw invalidRequest("Notification priority must be normal or high");
    }
    if (principal.kind === "agent" && priority === "high") {
      throw new ServiceError(403, "FORBIDDEN", "High-priority notifications require user approval");
    }
    return this.repository.saveNotificationSurface({
      id: crypto.randomUUID(),
      projectId,
      eventType,
      type: "notification",
      titleTemplate: title,
      bodyTemplate: body,
      ...(subtitle ? { subtitleTemplate: subtitle } : {}),
      sound: readNonEmptyString(input.sound) ?? "default",
      group: readNonEmptyString(input.group) ?? eventType.split(".")[0] ?? "general",
      priority,
      enabled: input.enabled !== false,
      version: 1,
      createdAt: new Date().toISOString(),
    });
  }

  async upsertLiveSurface(
    principal: Principal,
    projectId: string,
    surfaceKeyValue: string,
    input: unknown,
  ): Promise<LiveSurface> {
    await this.requireOwnedProject(principal, projectId);
    const surfaceKey = parseSurfaceKey(surfaceKeyValue);
    const body = asRecord(input);
    const type = parseLiveSurfaceType(body.type);
    const title = readBoundedString(body.title, "Surface title", 80);
    const subtitle = readOptionalBoundedString(body.subtitle, "Surface subtitle", 120);
    const content = parseLiveSurfaceContent(type, body);
    const action = parseLiveSurfaceAction(body.action);
    const now = new Date().toISOString();
    return this.repository.saveLiveSurface({
      id: crypto.randomUUID(),
      projectId,
      surfaceKey,
      type,
      title,
      ...(subtitle ? { subtitle } : {}),
      content,
      ...(action ? { action } : {}),
      version: 1,
      createdAt: now,
      updatedAt: now,
    });
  }

  async listLiveSurfaces(principal: Principal, projectId?: string) {
    const projects = projectId
      ? [await this.requireOwnedProject(principal, projectId)]
      : await this.repository.listProjects(principal.userId);
    const groups = await Promise.all(projects.map(async (project) => ({
      project,
      surfaces: await this.repository.listLiveSurfaces(project.id),
    })));
    return {
      surfaces: groups
        .flatMap(({ project, surfaces }) => surfaces.map((surface) => ({
          ...surface,
          project: { id: project.id, name: project.name, icon: project.icon },
        })))
        .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)),
    };
  }

  async deleteLiveSurface(
    principal: Principal,
    projectId: string,
    surfaceKeyValue: string,
  ): Promise<void> {
    await this.requireOwnedProject(principal, projectId);
    const surfaceKey = parseSurfaceKey(surfaceKeyValue);
    const surface = await this.repository.getLiveSurface(projectId, surfaceKey);
    if (!surface) throw new ServiceError(404, "SURFACE_NOT_FOUND", "Surface not found");
    await this.repository.deleteLiveSurface(surface.id);
  }

  async createIngestToken(
    principal: Principal,
    projectId: string,
    input: unknown,
  ): Promise<Omit<IngestToken, "tokenHash"> & { token: string }> {
    await this.requireOwnedProject(principal, projectId);
    const body = asRecord(input);
    const name = readNonEmptyString(body.name);
    if (!name) throw invalidRequest("Token name is required");
    const token = createOpaqueToken("ingest");
    const record: IngestToken = {
      id: crypto.randomUUID(),
      projectId,
      name,
      tokenHash: await hashSecret(token),
      scope: "event:ingest",
      createdAt: new Date().toISOString(),
      ...(readDateTime(body.expiresAt) ? { expiresAt: readDateTime(body.expiresAt) } : {}),
    };
    await this.repository.saveIngestToken(record);
    const { tokenHash, ...publicRecord } = record;
    void tokenHash;
    return { ...publicRecord, token };
  }

  async revokeIngestToken(principal: Principal, projectId: string, tokenId: string): Promise<void> {
    await this.requireOwnedProject(principal, projectId);
    const tokens = await this.repository.listIngestTokens(projectId);
    if (!tokens.some((token) => token.id === tokenId)) {
      throw new ServiceError(404, "INVALID_TOKEN", "Ingest token not found");
    }
    await this.repository.revokeIngestToken(tokenId, new Date().toISOString());
  }

  async ingestEvent(
    projectId: string,
    bearerToken: string | undefined,
    idempotencyKeyValue: string | undefined,
    input: IngestEventInput,
  ): Promise<IngestEventResult> {
    const project = await this.requireProject(projectId);
    const rawToken = readBearerToken(bearerToken);
    if (!rawToken) throw invalidToken();
    const storedToken = await this.repository.findIngestTokenByHash(
      projectId,
      await hashSecret(rawToken),
    );
    if (!storedToken) throw invalidToken();
    const allowed = await this.repository.consumeRateLimit(
      `${projectId}:${storedToken.id}`,
      60,
      60,
    );
    if (!allowed) {
      throw new ServiceError(429, "RATE_LIMITED", "Event rate limit exceeded");
    }
    const idempotencyKey = readNonEmptyString(idempotencyKeyValue);
    if (!idempotencyKey) {
      throw new ServiceError(400, "IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key header is required");
    }
    await this.repository.markIngestTokenUsed(storedToken.id, new Date().toISOString());
    return this.acceptEvent(project, idempotencyKey, input);
  }

  async sendTestEvent(principal: Principal, projectId: string, input: IngestEventInput) {
    const project = await this.requireOwnedProject(principal, projectId);
    return this.acceptEvent(project, `test-${crypto.randomUUID()}`, input);
  }

  async listEvents(
    principal: Principal,
    projectId: string,
    options: { cursor?: string; limit?: number; eventType?: string; unreadOnly?: boolean },
  ) {
    await this.requireOwnedProject(principal, projectId);
    const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
    const page = await this.repository.listEvents(projectId, { ...options, limit });
    return this.redactEventPage(page);
  }

  async listInbox(principal: Principal, options: { limit?: number; unreadOnly?: boolean }) {
    const projects = await this.repository.listProjects(principal.userId);
    const limit = Math.min(Math.max(options.limit ?? 30, 1), 100);
    const pages = await Promise.all(
      projects.map(async (project) => ({
        project,
        page: await this.redactEventPage(
          await this.repository.listEvents(project.id, {
            limit,
            unreadOnly: options.unreadOnly,
          }),
        ),
      })),
    );
    const events = pages
      .flatMap(({ project, page }) =>
        page.events.map((event) => ({ ...event, project: { id: project.id, name: project.name, icon: project.icon } })),
      )
      .sort((left, right) => right.receivedAt.localeCompare(left.receivedAt))
      .slice(0, limit);
    return { events };
  }

  async getEventDetail(principal: Principal, eventId: string) {
    const event = await this.repository.getEvent(eventId);
    if (!event) throw new ServiceError(404, "EVENT_NOT_FOUND", "Event not found");
    const project = await this.requireOwnedProject(principal, event.projectId);
    const deliveries = await this.repository.listDeliveries(event.id);
    return {
      ...event,
      project: { id: project.id, name: project.name, icon: project.icon },
      sensitiveFields: eventSensitiveFields(event),
      deliveries,
    };
  }

  async markEventRead(principal: Principal, eventId: string) {
    const event = await this.repository.getEvent(eventId);
    if (!event) throw new ServiceError(404, "EVENT_NOT_FOUND", "Event not found");
    await this.requireOwnedProject(principal, event.projectId);
    const readAt = event.readAt ?? new Date().toISOString();
    await this.repository.markEventRead(eventId, readAt);
    return { readAt };
  }

  async getDeliveryHealth(principal: Principal, projectId: string) {
    await this.requireOwnedProject(principal, projectId);
    return this.repository.getDeliveryHealth(projectId);
  }

  async getDeliveries(principal: Principal, eventId: string): Promise<{ deliveries: Delivery[] }> {
    const event = await this.repository.getEvent(eventId);
    if (!event) throw new ServiceError(404, "EVENT_NOT_FOUND", "Event not found");
    await this.requireOwnedProject(principal, event.projectId);
    return { deliveries: await this.repository.listDeliveries(eventId) };
  }

  private async acceptEvent(
    project: Project,
    idempotencyKey: string,
    input: IngestEventInput,
  ): Promise<IngestEventResult> {
    const eventType = readNonEmptyString(input.type);
    if (!eventType) throw invalidRequest("Event type is required");
    const schema = await this.repository.getEventSchema(project.id, eventType);
    if (!schema) {
      throw new ServiceError(
        422,
        "EVENT_SCHEMA_NOT_FOUND",
        `No active schema exists for event type ${eventType}`,
      );
    }
    const data = asRecord(input.data);
    const occurredAt = readDateTime(input.occurredAt);
    const issues = validateEventData(schema.fields, data);
    if (!occurredAt) issues.push({ field: "occurredAt", message: "must be a valid datetime string" });
    if (issues.length > 0) {
      throw new ServiceError(
        422,
        "SCHEMA_VALIDATION_FAILED",
        "Event data does not match its schema",
        issues,
      );
    }
    const event: BellwireEvent = {
      id: crypto.randomUUID(),
      projectId: project.id,
      eventType,
      idempotencyKey,
      data,
      sensitiveFields: Object.entries(schema.fields)
        .filter(([, definition]) => definition.sensitive === true)
        .map(([name]) => name),
      occurredAt: occurredAt as string,
      receivedAt: new Date().toISOString(),
      status: "accepted",
    };
    const saved = await this.repository.createEventIfAbsent(event);
    const previousQueueFailure = !saved.created && (await this.repository.listDeliveries(saved.event.id))
      .some((delivery) => delivery.errorCode === "retryable:QueueUnavailable");
    const deliveryQueued = project.status === "active" && (saved.created || previousQueueFailure)
      ? await this.dispatchEvent(project, saved.event)
      : undefined;
    return {
      eventId: saved.event.id,
      deduplicated: !saved.created,
      ...(deliveryQueued === undefined ? {} : { deliveryQueued }),
    };
  }

  private async dispatchEvent(
    project: Project,
    event: BellwireEvent,
  ): Promise<boolean | undefined> {
    if (!this.deliveryDispatcher) return undefined;
    const devices = (await this.repository.listDevices(project.userId))
      .filter((device) => device.pushEnabled);
    if (devices.length === 0) return undefined;
    try {
      await this.deliveryDispatcher.enqueue(event);
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message.slice(0, 240) : "Queue unavailable";
      console.error("Delivery queue enqueue failed", message);
      await Promise.allSettled(devices.map(async (device) => {
        const now = new Date().toISOString();
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
        if (result.delivery.status !== "queued" || result.delivery.attemptCount !== 0) return;
        await this.repository.recordQueueUnavailable(result.delivery, now, message);
      }));
      return false;
    }
  }

  private async createDefaultSurface(project: Project, schema: EventSchema): Promise<void> {
    await this.repository.saveNotificationSurface({
      id: crypto.randomUUID(),
      projectId: project.id,
      eventType: schema.eventType,
      type: "notification",
      titleTemplate: humanizeEventType(schema.eventType),
      bodyTemplate: `New event from ${project.name}`,
      sound: "default",
      group: schema.eventType.split(".")[0] ?? "general",
      priority: "normal",
      enabled: true,
      version: 1,
      createdAt: new Date().toISOString(),
    });
  }

  private async redactEventPage(
    page: Awaited<ReturnType<BellwireRepository["listEvents"]>>,
  ) {
    return {
      ...page,
      events: page.events.map((event) => {
        const sensitiveFields = eventSensitiveFields(event);
        const sensitive = new Set(sensitiveFields);
        const data = Object.fromEntries(
          Object.entries(event.data).filter(([name]) => !sensitive.has(name)),
        );
        return { ...event, data, sensitiveFields };
      }),
    };
  }

  private async requireProject(projectId: string): Promise<Project> {
    const project = await this.repository.getProject(projectId);
    if (!project) throw new ServiceError(404, "PROJECT_NOT_FOUND", "Project not found");
    return project;
  }

  private async requireOwnedProject(principal: Principal, projectId: string): Promise<Project> {
    const project = await this.requireProject(projectId);
    if (project.userId !== principal.userId) {
      throw new ServiceError(404, "PROJECT_NOT_FOUND", "Project not found");
    }
    return project;
  }
}

function eventSensitiveFields(event: BellwireEvent): string[] {
  return event.sensitiveFields ?? Object.keys(event.data);
}

function invalidRequest(message: string): ServiceError {
  return new ServiceError(400, "INVALID_REQUEST", message);
}

function invalidToken(): ServiceError {
  return new ServiceError(401, "INVALID_TOKEN", "Invalid ingest token");
}

function invalidBindingCode(): ServiceError {
  return new ServiceError(400, "INVALID_BINDING_CODE", "Binding code is invalid or expired");
}

function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return {};
  return value as Record<string, unknown>;
}

function readNonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readDateTime(value: unknown): string | undefined {
  const dateTime = readNonEmptyString(value);
  return dateTime && !Number.isNaN(Date.parse(dateTime)) ? dateTime : undefined;
}

function readBoundedString(value: unknown, name: string, maximum: number): string {
  const result = readNonEmptyString(value);
  if (!result) throw invalidRequest(`${name} is required`);
  if (result.length > maximum) throw invalidRequest(`${name} must be at most ${maximum} characters`);
  return result;
}

function readOptionalBoundedString(
  value: unknown,
  name: string,
  maximum: number,
): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return readBoundedString(value, name, maximum);
}

function parseSurfaceKey(value: unknown): string {
  const key = readNonEmptyString(value);
  if (!key || key.length > 80 || !/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/u.test(key)) {
    throw invalidRequest("surfaceKey must use lowercase letters, digits, dots, dashes, or underscores");
  }
  return key;
}

function parseLiveSurfaceType(value: unknown): LiveSurfaceType {
  if (typeof value !== "string" || !(LIVE_SURFACE_TYPES as readonly string[]).includes(value)) {
    throw invalidRequest(`Surface type must be one of: ${LIVE_SURFACE_TYPES.join(", ")}`);
  }
  return value as LiveSurfaceType;
}

const SURFACE_COLORS = [
  "lime", "green", "cyan", "blue", "purple", "magenta", "red", "orange", "yellow", "gray",
] as const;

function parseLiveSurfaceContent(
  type: LiveSurfaceType,
  body: Record<string, unknown>,
): Record<string, unknown> {
  switch (type) {
    case "stats":
      return { metrics: parseSurfaceMetrics(body.metrics, 8, false) };
    case "metrics":
      return { metrics: parseSurfaceMetrics(body.metrics, 4, true) };
    case "progress": {
      const percentage = readFiniteNumber(body.percentage);
      const value = readFiniteNumber(body.value);
      const upperLimit = readFiniteNumber(body.upperLimit);
      if (percentage !== undefined) {
        if (percentage < 0 || percentage > 100) throw invalidRequest("percentage must be between 0 and 100");
        return { percentage };
      }
      if (value === undefined || upperLimit === undefined || upperLimit <= 0 || value < 0 || value > upperLimit) {
        throw invalidRequest("progress requires percentage or value with a positive upperLimit");
      }
      return { value, upperLimit };
    }
    case "segmented_progress": {
      const numberOfSteps = readInteger(body.numberOfSteps);
      const currentStep = readInteger(body.currentStep);
      if (!numberOfSteps || numberOfSteps > 12) {
        throw invalidRequest("numberOfSteps must be between 1 and 12");
      }
      if (currentStep === undefined || currentStep < 0 || currentStep > numberOfSteps) {
        throw invalidRequest("currentStep must be between 0 and numberOfSteps");
      }
      const stepLabel = readOptionalBoundedString(body.stepLabel, "stepLabel", 80);
      return { numberOfSteps, currentStep, ...(stepLabel ? { stepLabel } : {}) };
    }
    case "alert": {
      const message = readBoundedString(body.message, "Alert message", 240);
      const icon = parseSurfaceAdornment(body.icon, "icon", true);
      const badge = parseSurfaceAdornment(body.badge, "badge", false);
      return { message, ...(icon ? { icon } : {}), ...(badge ? { badge } : {}) };
    }
    case "timer": {
      const durationSeconds = readInteger(body.durationSeconds);
      if (!durationSeconds || durationSeconds > 604_800) {
        throw invalidRequest("durationSeconds must be between 1 and 604800");
      }
      if (body.countsDown !== undefined && typeof body.countsDown !== "boolean") {
        throw invalidRequest("countsDown must be boolean");
      }
      return { durationSeconds, countsDown: body.countsDown !== false };
    }
  }
}

function parseSurfaceMetrics(value: unknown, maximum: number, numeric: boolean) {
  if (!Array.isArray(value) || value.length === 0 || value.length > maximum) {
    throw invalidRequest(`metrics must contain between 1 and ${maximum} items`);
  }
  return value.map((rawMetric, index) => {
    const metric = asRecord(rawMetric);
    const label = readBoundedString(metric.label, `metrics[${index}].label`, 40);
    const rawValue = metric.value;
    if (numeric) {
      if (readFiniteNumber(rawValue) === undefined) {
        throw invalidRequest(`metrics[${index}].value must be a number`);
      }
    } else if (
      !(typeof rawValue === "number" && Number.isFinite(rawValue)) &&
      !(typeof rawValue === "string" && rawValue.trim().length > 0 && rawValue.length <= 64)
    ) {
      throw invalidRequest(`metrics[${index}].value must be a short string or number`);
    }
    const unit = readOptionalBoundedString(metric.unit, `metrics[${index}].unit`, 16);
    const color = parseSurfaceColor(metric.color, `metrics[${index}].color`);
    return { label, value: rawValue, ...(unit ? { unit } : {}), ...(color ? { color } : {}) };
  });
}

function parseSurfaceAdornment(value: unknown, name: string, usesSymbol: boolean) {
  if (value === undefined || value === null) return undefined;
  const record = asRecord(value);
  const text = readBoundedString(
    usesSymbol ? record.symbol : record.title,
    `${name}.${usesSymbol ? "symbol" : "title"}`,
    usesSymbol ? 80 : 24,
  );
  if (usesSymbol && !/^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$/u.test(text)) {
    throw invalidRequest("icon.symbol must be an SF Symbol name");
  }
  const color = parseSurfaceColor(record.color, `${name}.color`);
  return { [usesSymbol ? "symbol" : "title"]: text, ...(color ? { color } : {}) };
}

function parseSurfaceColor(value: unknown, name: string): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || !(SURFACE_COLORS as readonly string[]).includes(value)) {
    throw invalidRequest(`${name} must be one of: ${SURFACE_COLORS.join(", ")}`);
  }
  return value;
}

function parseLiveSurfaceAction(value: unknown): LiveSurfaceAction | undefined {
  if (value === undefined || value === null) return undefined;
  const action = asRecord(value);
  if (action.type !== "open_url") throw invalidRequest("Surface action type must be open_url");
  const title = readBoundedString(action.title, "Action title", 40);
  const url = readBoundedString(action.url, "Action URL", 2_048);
  if (!isHttpUrl(url)) throw invalidRequest("Action URL must use http or https");
  return { type: "open_url", title, url };
}

function readFiniteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function readInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) ? value : undefined;
}

function parseEventType(value: unknown): string {
  const eventType = readNonEmptyString(value);
  if (!eventType || !/^[A-Za-z0-9]+(?:[._-][A-Za-z0-9]+)*$/u.test(eventType)) {
    throw invalidRequest("A valid eventType is required");
  }
  return eventType;
}

function parseFields(input: unknown): Record<string, EventFieldDefinition> {
  const rawFields = asRecord(input);
  if (Object.keys(rawFields).length === 0) throw invalidRequest("At least one event field is required");
  const fields: Record<string, EventFieldDefinition> = {};
  for (const [fieldName, rawDefinition] of Object.entries(rawFields)) {
    if (!/^[A-Za-z][A-Za-z0-9_]*$/u.test(fieldName)) {
      throw invalidRequest(`Invalid field name: ${fieldName}`);
    }
    const definition = asRecord(rawDefinition);
    const type = definition.type;
    if (!isEventFieldType(type)) throw invalidRequest(`Unsupported type for field ${fieldName}`);
    if (definition.required !== undefined && typeof definition.required !== "boolean") {
      throw invalidRequest(`required must be boolean for field ${fieldName}`);
    }
    if (definition.sensitive !== undefined && typeof definition.sensitive !== "boolean") {
      throw invalidRequest(`sensitive must be boolean for field ${fieldName}`);
    }
    const values = definition.values;
    if (
      type === "enum" &&
      (!Array.isArray(values) || values.length === 0 || values.some((item) => typeof item !== "string" || !item))
    ) {
      throw invalidRequest(`Enum field ${fieldName} requires non-empty string values`);
    }
    fields[fieldName] = {
      type,
      ...(definition.required === true ? { required: true } : {}),
      ...(definition.sensitive === true ? { sensitive: true } : {}),
      ...(type === "enum" ? { values: values as string[] } : {}),
    };
  }
  return fields;
}

function isEventFieldType(value: unknown): value is EventFieldType {
  return typeof value === "string" && (EVENT_FIELD_TYPES as readonly string[]).includes(value);
}

function validateEventData(
  fields: Record<string, EventFieldDefinition>,
  data: Record<string, unknown>,
): ValidationIssue[] {
  const issues: ValidationIssue[] = [];
  for (const [fieldName, definition] of Object.entries(fields)) {
    const value = data[fieldName];
    if (value === undefined || value === null) {
      if (definition.required) issues.push({ field: fieldName, message: "is required" });
      continue;
    }
    if (!matchesFieldType(definition, value)) {
      issues.push({
        field: fieldName,
        message: definition.type === "enum"
          ? `must be one of: ${definition.values?.join(", ")}`
          : `must be a valid ${definition.type}`,
      });
    }
  }
  const unexpected = Object.keys(data).filter((field) => fields[field] === undefined);
  for (const field of unexpected) issues.push({ field, message: "is not defined in the active schema" });
  return issues;
}

function matchesFieldType(definition: EventFieldDefinition, value: unknown): boolean {
  switch (definition.type) {
    case "string": return typeof value === "string";
    case "number": return typeof value === "number" && Number.isFinite(value);
    case "boolean": return typeof value === "boolean";
    case "datetime": return readDateTime(value) !== undefined;
    case "url": return isHttpUrl(value);
    case "enum": return typeof value === "string" && definition.values?.includes(value) === true;
  }
}

function isHttpUrl(value: unknown): boolean {
  if (typeof value !== "string") return false;
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:";
  } catch {
    return false;
  }
}

function validateTemplate(
  template: string,
  fields: Record<string, EventFieldDefinition>,
  fieldName: string,
): void {
  if (template.length > 240) throw invalidRequest(`${fieldName} template is too long`);
  const tokenPattern = /\{\{\s*([A-Za-z][A-Za-z0-9_]*)(?:\s*\|\s*default:\s*(['"])(.*?)\2)?\s*\}\}/gu;
  const referenced = [...template.matchAll(tokenPattern)];
  const remainder = template.replace(tokenPattern, "");
  if (remainder.includes("{{") || remainder.includes("}}")) {
    throw invalidRequest(`${fieldName} template contains unsupported syntax`);
  }
  for (const match of referenced) {
    const key = match[1] as string;
    const definition = fields[key];
    if (!definition) throw invalidRequest(`${fieldName} template references unknown field ${key}`);
    if (definition.sensitive) {
      throw invalidRequest(`${fieldName} template cannot display sensitive field ${key}`);
    }
  }
}

function slugify(value: string): string {
  const slug = value
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, "-")
    .replace(/^-|-$/gu, "")
    .slice(0, 40);
  return slug || "project";
}

function humanizeEventType(value: string): string {
  return value
    .split(/[._-]/u)
    .filter(Boolean)
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join(" ");
}

export function allAgentScopes(): AgentScope[] {
  return [...AGENT_SCOPES];
}
