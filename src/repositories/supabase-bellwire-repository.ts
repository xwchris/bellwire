// SPDX-License-Identifier: AGPL-3.0-only
import type {
  BellwireEvent,
  AgentToken,
  Delivery,
  DeliveryHealth,
  Device,
  DeviceBinding,
  DeviceKey,
  DirectConnectionEnvelope,
  EventListOptions,
  EventListPage,
  EventSchema,
  IngestToken,
  LiveSurface,
  NotificationPreference,
  NotificationSurface,
  Project,
} from "../domain/models";
import type {
  BellwireRepository,
  CreateDeliveryResult,
  CreateEventResult,
} from "./bellwire-repository";

type JsonRecord = Record<string, unknown>;

export class SupabaseRequestError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown,
  ) {
    super(`Supabase request failed with status ${status}`);
    this.name = "SupabaseRequestError";
  }
}

export class SupabaseBellwireRepository implements BellwireRepository {
  private readonly restBaseUrl: string;
  private readonly authBaseUrl: string;

  constructor(
    supabaseUrl: string,
    private readonly serviceRoleKey: string,
    private readonly fetchImpl: typeof fetch = (input, init) => fetch(input, init),
  ) {
    const baseUrl = supabaseUrl.replace(/\/$/u, "");
    this.restBaseUrl = `${baseUrl}/rest/v1`;
    this.authBaseUrl = `${baseUrl}/auth/v1`;
  }

  async deleteAccount(userId: string): Promise<void> {
    const response = await this.fetchImpl(
      `${this.authBaseUrl}/admin/users/${encodeURIComponent(userId)}`,
      {
        method: "DELETE",
        headers: {
          apikey: this.serviceRoleKey,
          authorization: `Bearer ${this.serviceRoleKey}`,
          "content-type": "application/json",
        },
      },
    );
    if (response.ok) return;
    const text = await response.text();
    let body: unknown = text;
    try {
      body = JSON.parse(text) as unknown;
    } catch {
      // Preserve non-JSON Auth responses for diagnostics.
    }
    throw new SupabaseRequestError(response.status, body);
  }

  async saveAppleRefreshToken(userId: string, encryptedRefreshToken: string): Promise<void> {
    await this.request("/apple_auth_tokens?on_conflict=user_id", {
      method: "POST",
      body: {
        user_id: userId,
        refresh_token_ciphertext: encryptedRefreshToken,
        updated_at: new Date().toISOString(),
      },
      prefer: "resolution=merge-duplicates,return=minimal",
    });
  }

  async getAppleRefreshToken(userId: string): Promise<string | undefined> {
    return this.one(
      "/apple_auth_tokens",
      { user_id: `eq.${userId}`, select: "refresh_token_ciphertext" },
      (row) => optionalString(row.refresh_token_ciphertext),
    );
  }

  async deleteAppleRefreshToken(userId: string): Promise<void> {
    await this.request(`/apple_auth_tokens?${params({ user_id: `eq.${userId}` })}`, {
      method: "DELETE",
    });
  }

  async createProject(project: Project): Promise<Project> {
    const rows = await this.request<JsonRecord[]>("/projects", {
      method: "POST",
      body: projectRow(project),
      prefer: "return=representation",
    });
    return toProject(requiredFirst(rows));
  }

  async getProject(projectId: string): Promise<Project | undefined> {
    return this.one("/projects", { id: `eq.${projectId}` }, toProject);
  }

  async listProjects(userId: string): Promise<Project[]> {
    const rows = await this.getRows("/projects", {
      user_id: `eq.${userId}`,
      order: "display_order.asc,id.asc",
    });
    return rows.map(toProject);
  }

  async updateProject(project: Project): Promise<Project> {
    const rows = await this.request<JsonRecord[]>(
      `/projects?${params({ id: `eq.${project.id}` })}`,
      { method: "PATCH", body: projectRow(project), prefer: "return=representation" },
    );
    return toProject(requiredFirst(rows));
  }

  async updateProjectDisplayOrder(projectId: string, displayOrder: number): Promise<Project> {
    const rows = await this.request<JsonRecord[]>(
      `/projects?${params({ id: `eq.${projectId}` })}`,
      { method: "PATCH", body: { display_order: displayOrder }, prefer: "return=representation" },
    );
    return toProject(requiredFirst(rows));
  }

  async deleteProject(projectId: string): Promise<void> {
    await this.request(`/projects?${params({ id: `eq.${projectId}` })}`, { method: "DELETE" });
  }

  async saveDevice(device: Device): Promise<Device> {
    const rows = await this.request<JsonRecord[]>("/rpc/register_device", {
      method: "POST",
      body: {
        p_id: device.id,
        p_user_id: device.userId,
        p_installation_id: device.installationId,
        p_name: device.name,
        p_apns_token: device.apnsToken,
        p_apns_environment: device.apnsEnvironment,
        p_app_version: device.appVersion ?? null,
        p_last_active_at: device.lastActiveAt,
        p_push_enabled: device.pushEnabled,
        p_created_at: device.createdAt,
      },
    });
    return toDevice(requiredFirst(rows));
  }

  async getDevice(deviceId: string): Promise<Device | undefined> {
    return this.one("/devices", { id: `eq.${deviceId}` }, toDevice);
  }

  async listDevices(userId: string): Promise<Device[]> {
    const rows = await this.getRows("/devices", {
      user_id: `eq.${userId}`,
      order: "last_active_at.desc",
    });
    return rows.map(toDevice);
  }

  async deleteDevice(deviceId: string): Promise<void> {
    await this.request(`/devices?${params({ id: `eq.${deviceId}` })}`, { method: "DELETE" });
  }

  async getNotificationPreference(userId: string): Promise<NotificationPreference | undefined> {
    return this.one(
      "/notification_preferences",
      { user_id: `eq.${userId}` },
      toNotificationPreference,
    );
  }

  async saveNotificationPreference(
    preference: NotificationPreference,
  ): Promise<NotificationPreference> {
    const rows = await this.request<JsonRecord[]>("/notification_preferences?on_conflict=user_id", {
      method: "POST",
      body: {
        user_id: preference.userId,
        mode: preference.mode,
        updated_at: preference.updatedAt,
      },
      prefer: "resolution=merge-duplicates,return=representation",
    });
    return toNotificationPreference(requiredFirst(rows));
  }

  async saveDeviceBinding(binding: DeviceBinding): Promise<DeviceBinding> {
    const rows = await this.request<JsonRecord[]>("/device_bindings", {
      method: "POST",
      body: bindingRow(binding),
      prefer: "return=representation",
    });
    return toDeviceBinding(requiredFirst(rows));
  }

  async findDeviceBindingByCodeHash(codeHash: string): Promise<DeviceBinding | undefined> {
    return this.one(
      "/device_bindings",
      { code_hash: `eq.${codeHash}` },
      toDeviceBinding,
    );
  }

  async claimDeviceBinding(
    codeHash: string,
    token: Omit<AgentToken, "userId">,
    consumedAt: string,
  ): Promise<AgentToken | undefined> {
    const rows = await this.request<JsonRecord[]>("/rpc/claim_device_binding", {
      method: "POST",
      body: {
        p_code_hash: codeHash,
        p_consumed_at: consumedAt,
        p_token_id: token.id,
        p_token_name: token.name,
        p_token_hash: token.tokenHash,
        p_token_scopes: token.scopes,
        p_token_created_at: token.createdAt,
      },
    });
    return rows[0] ? toAgentToken(rows[0]) : undefined;
  }

  async saveAgentToken(token: AgentToken): Promise<AgentToken> {
    const rows = await this.request<JsonRecord[]>("/agent_tokens", {
      method: "POST",
      body: agentTokenRow(token),
      prefer: "return=representation",
    });
    return toAgentToken(requiredFirst(rows));
  }

  async listAgentTokens(userId: string): Promise<AgentToken[]> {
    const rows = await this.getRows("/agent_tokens", {
      user_id: `eq.${userId}`,
      revoked_at: "is.null",
      order: "created_at.desc",
    });
    return rows.map(toAgentToken);
  }

  async findAgentTokenByHash(tokenHash: string): Promise<AgentToken | undefined> {
    return this.one(
      "/agent_tokens",
      {
        token_hash: `eq.${tokenHash}`,
        revoked_at: "is.null",
        or: `(expires_at.is.null,expires_at.gt.${new Date().toISOString()})`,
      },
      toAgentToken,
    );
  }

  async markAgentTokenUsed(tokenId: string, usedAt: string): Promise<void> {
    await this.request(`/agent_tokens?${params({ id: `eq.${tokenId}` })}`, {
      method: "PATCH",
      body: { last_used_at: usedAt },
    });
  }

  async revokeAgentToken(tokenId: string, userId: string, revokedAt: string): Promise<void> {
    await this.request(`/agent_tokens?${params({
      id: `eq.${tokenId}`,
      user_id: `eq.${userId}`,
    })}`, {
      method: "PATCH",
      body: { revoked_at: revokedAt },
    });
  }

  async saveDeviceKey(key: DeviceKey): Promise<DeviceKey> {
    const rows = await this.request<JsonRecord[]>("/device_keys?on_conflict=user_id,installation_id", {
      method: "POST",
      body: deviceKeyRow(key),
      prefer: "resolution=merge-duplicates,return=representation",
    });
    return toDeviceKey(requiredFirst(rows));
  }

  async getDeviceKey(keyId: string, userId: string): Promise<DeviceKey | undefined> {
    return this.one(
      "/device_keys",
      { id: `eq.${keyId}`, user_id: `eq.${userId}`, revoked_at: "is.null" },
      toDeviceKey,
    );
  }

  async saveDirectConnectionEnvelope(
    envelope: DirectConnectionEnvelope,
  ): Promise<DirectConnectionEnvelope> {
    const rows = await this.request<JsonRecord[]>("/direct_connection_envelopes", {
      method: "POST",
      body: directConnectionEnvelopeRow(envelope),
      prefer: "return=representation",
    });
    return toDirectConnectionEnvelope(requiredFirst(rows));
  }

  async listDirectConnectionEnvelopes(
    userId: string,
    deviceKeyId: string,
    now: string,
  ): Promise<DirectConnectionEnvelope[]> {
    const rows = await this.getRows("/direct_connection_envelopes", {
      user_id: `eq.${userId}`,
      device_key_id: `eq.${deviceKeyId}`,
      expires_at: `gt.${now}`,
      order: "created_at.asc",
    });
    return rows.map(toDirectConnectionEnvelope);
  }

  async deleteDirectConnectionEnvelope(envelopeId: string, userId: string): Promise<void> {
    await this.request(`/direct_connection_envelopes?${params({
      id: `eq.${envelopeId}`,
      user_id: `eq.${userId}`,
    })}`, { method: "DELETE" });
  }

  async saveEventSchema(schema: EventSchema): Promise<EventSchema> {
    const rows = await this.request<JsonRecord[]>("/rpc/save_event_schema_version", {
      method: "POST",
      body: {
        p_id: schema.id,
        p_project_id: schema.projectId,
        p_event_type: schema.eventType,
        p_fields: schema.fields,
        p_status: schema.status,
        p_created_at: schema.createdAt,
      },
    });
    return toEventSchema(requiredFirst(rows));
  }

  async getEventSchema(projectId: string, eventType: string): Promise<EventSchema | undefined> {
    return this.one(
      "/event_schemas",
      {
        project_id: `eq.${projectId}`,
        event_type: `eq.${eventType}`,
        status: "eq.active",
        order: "version.desc",
      },
      toEventSchema,
    );
  }

  async listEventSchemas(projectId: string): Promise<EventSchema[]> {
    const rows = await this.getRows("/active_event_schemas", {
      project_id: `eq.${projectId}`,
      order: "event_type.asc",
    });
    return rows.map(toEventSchema);
  }

  async saveNotificationSurface(surface: NotificationSurface): Promise<NotificationSurface> {
    const rows = await this.request<JsonRecord[]>("/rpc/save_notification_surface_version", {
      method: "POST",
      body: {
        p_id: surface.id,
        p_project_id: surface.projectId,
        p_event_type: surface.eventType,
        p_title_template: surface.titleTemplate,
        p_body_template: surface.bodyTemplate,
        p_subtitle_template: surface.subtitleTemplate ?? null,
        p_sound: surface.sound,
        p_group_name: surface.group,
        p_priority: surface.priority,
        p_enabled: surface.enabled,
        p_created_at: surface.createdAt,
      },
    });
    return toSurface(requiredFirst(rows));
  }

  async getNotificationSurface(
    projectId: string,
    eventType: string,
  ): Promise<NotificationSurface | undefined> {
    return this.one(
      "/notification_surfaces",
      {
        project_id: `eq.${projectId}`,
        event_type: `eq.${eventType}`,
        order: "version.desc",
      },
      toSurface,
    );
  }

  async listNotificationSurfaces(projectId: string): Promise<NotificationSurface[]> {
    const rows = await this.getRows("/active_notification_surfaces", {
      project_id: `eq.${projectId}`,
      order: "event_type.asc",
    });
    return rows.map(toSurface);
  }

  async saveLiveSurface(surface: LiveSurface): Promise<LiveSurface> {
    const rows = await this.request<JsonRecord[]>("/rpc/save_live_surface_version", {
      method: "POST",
      body: {
        p_id: surface.id,
        p_project_id: surface.projectId,
        p_surface_key: surface.surfaceKey,
        p_type: surface.type,
        p_title: surface.title,
        p_subtitle: surface.subtitle ?? null,
        p_content: surface.content,
        p_action: surface.action ?? null,
        p_display_order: surface.displayOrder,
        p_created_at: surface.createdAt,
        p_updated_at: surface.updatedAt,
      },
    });
    return toLiveSurface(requiredFirst(rows));
  }

  async getLiveSurface(projectId: string, surfaceKey: string): Promise<LiveSurface | undefined> {
    return this.one(
      "/live_surfaces",
      { project_id: `eq.${projectId}`, surface_key: `eq.${surfaceKey}` },
      toLiveSurface,
    );
  }

  async listLiveSurfaces(projectId: string): Promise<LiveSurface[]> {
    const rows = await this.getRows("/live_surfaces", {
      project_id: `eq.${projectId}`,
      order: "display_order.asc,id.asc",
    });
    return rows.map(toLiveSurface);
  }

  async updateLiveSurfaceDisplayOrder(surfaceId: string, displayOrder: number): Promise<LiveSurface> {
    const rows = await this.request<JsonRecord[]>(
      `/live_surfaces?${params({ id: `eq.${surfaceId}` })}`,
      { method: "PATCH", body: { display_order: displayOrder }, prefer: "return=representation" },
    );
    return toLiveSurface(requiredFirst(rows));
  }

  async deleteLiveSurface(surfaceId: string): Promise<void> {
    await this.request(`/live_surfaces?${params({ id: `eq.${surfaceId}` })}`, { method: "DELETE" });
  }

  async saveIngestToken(token: IngestToken): Promise<IngestToken> {
    const rows = await this.request<JsonRecord[]>("/ingest_tokens", {
      method: "POST",
      body: ingestTokenRow(token),
      prefer: "return=representation",
    });
    return toIngestToken(requiredFirst(rows));
  }

  async listIngestTokens(projectId: string): Promise<IngestToken[]> {
    const rows = await this.getRows("/ingest_tokens", {
      project_id: `eq.${projectId}`,
      order: "created_at.desc",
    });
    return rows.map(toIngestToken);
  }

  async findIngestTokenByHash(
    projectId: string,
    tokenHash: string,
  ): Promise<IngestToken | undefined> {
    return this.one(
      "/ingest_tokens",
      {
        project_id: `eq.${projectId}`,
        token_hash: `eq.${tokenHash}`,
        revoked_at: "is.null",
        or: `(expires_at.is.null,expires_at.gt.${new Date().toISOString()})`,
      },
      toIngestToken,
    );
  }

  async markIngestTokenUsed(tokenId: string, usedAt: string): Promise<void> {
    await this.request(`/ingest_tokens?${params({ id: `eq.${tokenId}` })}`, {
      method: "PATCH",
      body: { last_used_at: usedAt },
    });
  }

  async revokeIngestToken(tokenId: string, revokedAt: string): Promise<void> {
    await this.request(`/ingest_tokens?${params({ id: `eq.${tokenId}` })}`, {
      method: "PATCH",
      body: { revoked_at: revokedAt },
    });
  }

  async consumeRateLimit(key: string, limit: number, windowSeconds: number): Promise<boolean> {
    return this.request<boolean>("/rpc/consume_ingest_quota", {
      method: "POST",
      body: { p_key: key, p_limit: limit, p_window_seconds: windowSeconds },
    });
  }

  async createEventIfAbsent(event: BellwireEvent): Promise<CreateEventResult> {
    const inserted = await this.request<JsonRecord[]>(
      "/events?on_conflict=project_id,idempotency_key",
      {
        method: "POST",
        body: eventRow(event),
        prefer: "resolution=ignore-duplicates,return=representation",
      },
    );
    if (inserted[0]) return { event: toEvent(inserted[0]), created: true };
    const existing = await this.one(
      "/events",
      {
        project_id: `eq.${event.projectId}`,
        idempotency_key: `eq.${event.idempotencyKey}`,
      },
      toEvent,
    );
    if (!existing) throw new Error("Event idempotency conflict could not be resolved");
    return { event: existing, created: false };
  }

  async listEvents(projectId: string, options: EventListOptions): Promise<EventListPage> {
    const query: Record<string, string> = {
      project_id: `eq.${projectId}`,
      order: "received_at.desc",
      limit: String(options.limit + 1),
    };
    if (options.cursor) query.received_at = `lt.${options.cursor}`;
    if (options.eventType) query.event_type = `eq.${options.eventType}`;
    if (options.unreadOnly) query.read_at = "is.null";
    const rows = await this.getRows("/events", query);
    const hasMore = rows.length > options.limit;
    const events = rows.slice(0, options.limit).map(toEvent);
    return {
      events,
      ...(hasMore && events.at(-1) ? { nextCursor: events.at(-1)?.receivedAt } : {}),
    };
  }

  async getEvent(eventId: string): Promise<BellwireEvent | undefined> {
    return this.one("/events", { id: `eq.${eventId}` }, toEvent);
  }

  async markEventRead(eventId: string, readAt: string): Promise<void> {
    await this.request(`/events?${params({ id: `eq.${eventId}` })}`, {
      method: "PATCH",
      body: { read_at: readAt },
    });
  }

  async markAllEventsRead(projectIds: string[], readAt: string): Promise<number> {
    if (projectIds.length === 0) return 0;
    const rows = await this.request<JsonRecord[]>(
      `/events?${params({
        project_id: `in.(${projectIds.join(",")})`,
        read_at: "is.null",
        select: "id",
      })}`,
      { method: "PATCH", body: { read_at: readAt }, prefer: "return=representation" },
    );
    return rows.length;
  }

  async createDeliveryIfAbsent(delivery: Delivery): Promise<CreateDeliveryResult> {
    const rows = await this.request<JsonRecord[]>(
      "/deliveries?on_conflict=event_id,device_id",
      {
        method: "POST",
        body: deliveryRow(delivery),
        prefer: "resolution=ignore-duplicates,return=representation",
      },
    );
    if (rows[0]) return { delivery: toDelivery(rows[0]), created: true };
    const existing = await this.one(
      "/deliveries",
      { event_id: `eq.${delivery.eventId}`, device_id: `eq.${delivery.deviceId}` },
      toDelivery,
    );
    if (!existing) throw new Error("Delivery conflict could not be resolved");
    return { delivery: existing, created: false };
  }

  async claimDelivery(
    deliveryId: string,
    claimedAt: string,
    leaseSeconds: number,
    maxAttempts: number,
  ): Promise<Delivery | undefined> {
    const rows = await this.request<JsonRecord[]>("/rpc/claim_delivery", {
      method: "POST",
      body: {
        p_delivery_id: deliveryId,
        p_claimed_at: claimedAt,
        p_lease_seconds: leaseSeconds,
        p_max_attempts: maxAttempts,
      },
    });
    return rows[0] ? toDelivery(rows[0]) : undefined;
  }

  async completeClaimedDelivery(delivery: Delivery): Promise<Delivery | undefined> {
    const rows = await this.request<JsonRecord[]>(
      `/deliveries?${params({
        id: `eq.${delivery.id}`,
        status: "eq.queued",
        attempt_count: `eq.${delivery.attemptCount}`,
      })}`,
      { method: "PATCH", body: deliveryRow(delivery), prefer: "return=representation" },
    );
    return rows[0] ? toDelivery(rows[0]) : undefined;
  }

  async recordQueueUnavailable(
    expected: Delivery,
    failedAt: string,
    message: string,
  ): Promise<Delivery | undefined> {
    const rows = await this.request<JsonRecord[]>("/rpc/record_queue_unavailable", {
      method: "POST",
      body: {
        p_delivery_id: expected.id,
        p_expected_status: expected.status,
        p_expected_attempt_count: expected.attemptCount,
        p_expected_updated_at: expected.updatedAt,
        p_failed_at: failedAt,
        p_error_message: message,
      },
    });
    return rows[0] ? toDelivery(rows[0]) : undefined;
  }

  async updateDelivery(delivery: Delivery): Promise<Delivery> {
    const rows = await this.request<JsonRecord[]>(
      `/deliveries?${params({ id: `eq.${delivery.id}` })}`,
      { method: "PATCH", body: deliveryRow(delivery), prefer: "return=representation" },
    );
    return toDelivery(requiredFirst(rows));
  }

  async listDeliveries(eventId: string): Promise<Delivery[]> {
    const rows = await this.getRows("/deliveries", {
      event_id: `eq.${eventId}`,
      order: "queued_at.asc",
    });
    return rows.map(toDelivery);
  }

  async getDeliveryHealth(projectId: string, since: string): Promise<DeliveryHealth> {
    const rows = await this.getRows("/deliveries", {
      select: "status,events!inner(project_id)",
      "events.project_id": `eq.${projectId}`,
      updated_at: `gte.${since}`,
    });
    const statuses = rows.map((row) => String(row.status));
    const queued = statuses.filter((status) => status === "queued").length;
    const accepted = statuses.filter((status) => status === "accepted_by_apns").length;
    const failed = statuses.filter((status) => status === "failed").length;
    return {
      queued,
      accepted,
      failed,
      status: statuses.length === 0 ? "idle" : failed > 0 ? "degraded" : "healthy",
    };
  }

  private async one<T>(
    path: string,
    query: Record<string, string>,
    transform: (row: JsonRecord) => T,
  ): Promise<T | undefined> {
    const rows = await this.getRows(path, { ...query, limit: "1" });
    return rows[0] ? transform(rows[0]) : undefined;
  }

  private getRows(path: string, query: Record<string, string>): Promise<JsonRecord[]> {
    return this.request<JsonRecord[]>(`${path}?${params(query)}`, { method: "GET" });
  }

  private async request<T = unknown>(
    path: string,
    options: { method: string; body?: unknown; prefer?: string },
  ): Promise<T> {
    const response = await this.fetchImpl(`${this.restBaseUrl}${path}`, {
      method: options.method,
      headers: {
        apikey: this.serviceRoleKey,
        authorization: `Bearer ${this.serviceRoleKey}`,
        "content-type": "application/json",
        ...(options.prefer ? { prefer: options.prefer } : {}),
      },
      ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
    });
    const text = await response.text();
    if (!response.ok) {
      let body: unknown = text;
      try {
        body = JSON.parse(text) as unknown;
      } catch {
        // Preserve non-JSON PostgREST responses for diagnostics.
      }
      throw new SupabaseRequestError(response.status, body);
    }
    if (response.status === 204 || text.length === 0) return undefined as T;
    return JSON.parse(text) as T;
  }
}

function params(values: Record<string, string>): string {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) query.set(key, value);
  return query.toString();
}

function requiredFirst(rows: JsonRecord[]): JsonRecord {
  const row = rows[0];
  if (!row) throw new Error("Supabase did not return the saved row");
  return row;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function projectRow(value: Project): JsonRecord {
  return {
    id: value.id, user_id: value.userId, name: value.name, slug: value.slug,
    icon: value.icon, logo_url: value.logoUrl ?? null, display_order: value.displayOrder,
    category: value.category, status: value.status,
    endpoint: value.endpoint, created_at: value.createdAt, updated_at: value.updatedAt,
  };
}

function toProject(row: JsonRecord): Project {
  return {
    id: String(row.id), userId: String(row.user_id), name: String(row.name),
    slug: String(row.slug), icon: String(row.icon), logoUrl: optionalString(row.logo_url),
    displayOrder: Number(row.display_order), category: String(row.category),
    status: row.status === "paused" ? "paused" : "active", endpoint: String(row.endpoint),
    createdAt: String(row.created_at), updatedAt: String(row.updated_at),
  };
}

function toDevice(row: JsonRecord): Device {
  return {
    id: String(row.id), userId: String(row.user_id), installationId: String(row.installation_id),
    name: String(row.name), platform: "ios",
    apnsToken: String(row.apns_token),
    apnsEnvironment: row.apns_environment === "sandbox" ? "sandbox" : "production",
    appVersion: optionalString(row.app_version),
    lastActiveAt: String(row.last_active_at), pushEnabled: row.push_enabled === true,
    createdAt: String(row.created_at),
  };
}

function bindingRow(value: DeviceBinding): JsonRecord {
  return {
    id: value.id, user_id: value.userId, code_hash: value.codeHash,
    device_key_id: value.deviceKeyId ?? null,
    expires_at: value.expiresAt, consumed_at: value.consumedAt ?? null, created_at: value.createdAt,
  };
}

function toDeviceBinding(row: JsonRecord): DeviceBinding {
  return {
    id: String(row.id), userId: String(row.user_id), codeHash: String(row.code_hash),
    deviceKeyId: optionalString(row.device_key_id),
    expiresAt: String(row.expires_at), consumedAt: optionalString(row.consumed_at),
    createdAt: String(row.created_at),
  };
}

function toNotificationPreference(row: JsonRecord): NotificationPreference {
  const mode = String(row.mode);
  return {
    userId: String(row.user_id),
    mode: mode === "generic" || mode === "hosted_detailed"
      ? mode
      : "local_enrichment",
    updatedAt: String(row.updated_at),
  };
}

function deviceKeyRow(value: DeviceKey): JsonRecord {
  return {
    id: value.id,
    user_id: value.userId,
    installation_id: value.installationId,
    agreement_public_key: value.agreementPublicKey,
    signing_public_key: value.signingPublicKey,
    algorithm: value.algorithm,
    created_at: value.createdAt,
    last_active_at: value.lastActiveAt,
    revoked_at: value.revokedAt ?? null,
  };
}

function toDeviceKey(row: JsonRecord): DeviceKey {
  return {
    id: String(row.id),
    userId: String(row.user_id),
    installationId: String(row.installation_id),
    agreementPublicKey: String(row.agreement_public_key),
    signingPublicKey: String(row.signing_public_key),
    algorithm: "p256",
    createdAt: String(row.created_at),
    lastActiveAt: String(row.last_active_at),
    revokedAt: optionalString(row.revoked_at),
  };
}

function directConnectionEnvelopeRow(value: DirectConnectionEnvelope): JsonRecord {
  return {
    id: value.id,
    user_id: value.userId,
    device_key_id: value.deviceKeyId,
    algorithm: value.algorithm,
    ephemeral_public_key: value.ephemeralPublicKey,
    sealed_box: value.sealedBox,
    created_at: value.createdAt,
    expires_at: value.expiresAt,
  };
}

function toDirectConnectionEnvelope(row: JsonRecord): DirectConnectionEnvelope {
  return {
    id: String(row.id),
    userId: String(row.user_id),
    deviceKeyId: String(row.device_key_id),
    algorithm: "p256-hkdf-sha256-aes-gcm",
    ephemeralPublicKey: String(row.ephemeral_public_key),
    sealedBox: String(row.sealed_box),
    createdAt: String(row.created_at),
    expiresAt: String(row.expires_at),
  };
}

function agentTokenRow(value: AgentToken): JsonRecord {
  return {
    id: value.id, user_id: value.userId, name: value.name, token_hash: value.tokenHash,
    scopes: value.scopes, created_at: value.createdAt, last_used_at: value.lastUsedAt ?? null,
    expires_at: value.expiresAt ?? null, revoked_at: value.revokedAt ?? null,
  };
}

function toAgentToken(row: JsonRecord): AgentToken {
  return {
    id: String(row.id), userId: String(row.user_id), name: String(row.name),
    tokenHash: String(row.token_hash), scopes: row.scopes as AgentToken["scopes"],
    createdAt: String(row.created_at), lastUsedAt: optionalString(row.last_used_at),
    expiresAt: optionalString(row.expires_at), revokedAt: optionalString(row.revoked_at),
  };
}

function toEventSchema(row: JsonRecord): EventSchema {
  return {
    id: String(row.id), projectId: String(row.project_id), eventType: String(row.event_type),
    fields: row.fields as EventSchema["fields"], version: Number(row.version),
    status: "active", createdAt: String(row.created_at),
  };
}

function toSurface(row: JsonRecord): NotificationSurface {
  return {
    id: String(row.id), projectId: String(row.project_id), eventType: String(row.event_type),
    type: "notification", titleTemplate: String(row.title_template), bodyTemplate: String(row.body_template),
    subtitleTemplate: optionalString(row.subtitle_template), sound: String(row.sound),
    group: String(row.group_name), priority: row.priority === "high" ? "high" : "normal",
    enabled: row.enabled === true, version: Number(row.version), createdAt: String(row.created_at),
  };
}

function toLiveSurface(row: JsonRecord): LiveSurface {
  return {
    id: String(row.id), projectId: String(row.project_id), surfaceKey: String(row.surface_key),
    type: row.type as LiveSurface["type"], title: String(row.title),
    subtitle: optionalString(row.subtitle), content: row.content as Record<string, unknown>,
    ...(row.action && typeof row.action === "object"
      ? { action: row.action as unknown as LiveSurface["action"] }
      : {}),
    displayOrder: Number(row.display_order), version: Number(row.version),
    createdAt: String(row.created_at), updatedAt: String(row.updated_at),
  };
}

function ingestTokenRow(value: IngestToken): JsonRecord {
  return {
    id: value.id, project_id: value.projectId, name: value.name, token_hash: value.tokenHash,
    scope: value.scope, created_at: value.createdAt, last_used_at: value.lastUsedAt ?? null,
    expires_at: value.expiresAt ?? null, revoked_at: value.revokedAt ?? null,
  };
}

function toIngestToken(row: JsonRecord): IngestToken {
  return {
    id: String(row.id), projectId: String(row.project_id), name: String(row.name),
    tokenHash: String(row.token_hash), scope: "event:ingest", createdAt: String(row.created_at),
    lastUsedAt: optionalString(row.last_used_at), expiresAt: optionalString(row.expires_at),
    revokedAt: optionalString(row.revoked_at),
  };
}

function eventRow(value: BellwireEvent): JsonRecord {
  return {
    id: value.id, project_id: value.projectId, event_type: value.eventType,
    idempotency_key: value.idempotencyKey, data: value.data,
    sensitive_fields: value.sensitiveFields ?? Object.keys(value.data), occurred_at: value.occurredAt,
    received_at: value.receivedAt, status: value.status, read_at: value.readAt ?? null,
  };
}

function toEvent(row: JsonRecord): BellwireEvent {
  const data = row.data as Record<string, unknown>;
  return {
    id: String(row.id), projectId: String(row.project_id), eventType: String(row.event_type),
    idempotencyKey: String(row.idempotency_key), data,
    sensitiveFields: Array.isArray(row.sensitive_fields)
      ? row.sensitive_fields.filter((value): value is string => typeof value === "string")
      : Object.keys(data),
    occurredAt: String(row.occurred_at), receivedAt: String(row.received_at), status: "accepted",
    readAt: optionalString(row.read_at),
  };
}

function deliveryRow(value: Delivery): JsonRecord {
  return {
    id: value.id, event_id: value.eventId, device_id: value.deviceId, channel: value.channel,
    status: value.status, attempt_count: value.attemptCount,
    provider_message_id: value.providerMessageId ?? null, error_code: value.errorCode ?? null,
    error_message: value.errorMessage ?? null, queued_at: value.queuedAt,
    sent_at: value.sentAt ?? null, updated_at: value.updatedAt,
  };
}

function toDelivery(row: JsonRecord): Delivery {
  const rawStatus = String(row.status);
  return {
    id: String(row.id), eventId: String(row.event_id), deviceId: String(row.device_id), channel: "apns",
    status: rawStatus === "accepted_by_apns" ? "accepted_by_apns" : rawStatus === "failed" ? "failed" : "queued",
    attemptCount: Number(row.attempt_count), providerMessageId: optionalString(row.provider_message_id),
    errorCode: optionalString(row.error_code), errorMessage: optionalString(row.error_message),
    queuedAt: String(row.queued_at), sentAt: optionalString(row.sent_at), updatedAt: String(row.updated_at),
  };
}
