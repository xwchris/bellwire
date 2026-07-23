// SPDX-License-Identifier: AGPL-3.0-only
export const EVENT_FIELD_TYPES = [
  "string",
  "number",
  "boolean",
  "datetime",
  "url",
  "enum",
] as const;

export type EventFieldType = (typeof EVENT_FIELD_TYPES)[number];

export interface EventFieldDefinition {
  type: EventFieldType;
  required?: boolean;
  values?: string[];
  sensitive?: boolean;
}

export const AGENT_SCOPES = [
  "project:read",
  "project:write",
  "config:read",
  "config:write",
  "event:test",
  "delivery:read",
] as const;

export type AgentScope = (typeof AGENT_SCOPES)[number];

export interface Principal {
  kind: "user" | "agent";
  userId: string;
  tokenId?: string;
  scopes: AgentScope[];
}

export interface Project {
  id: string;
  userId: string;
  name: string;
  slug: string;
  icon: string;
  logoUrl?: string;
  displayOrder: number;
  category: string;
  status: "active" | "paused";
  endpoint: string;
  createdAt: string;
  updatedAt: string;
}

export interface Device {
  id: string;
  userId: string;
  installationId: string;
  name: string;
  platform: "ios";
  apnsToken: string;
  apnsEnvironment: "sandbox" | "production";
  appVersion?: string;
  lastActiveAt: string;
  pushEnabled: boolean;
  createdAt: string;
}

export interface DeviceBinding {
  id: string;
  userId: string;
  codeHash: string;
  expiresAt: string;
  consumedAt?: string;
  createdAt: string;
}

export interface AgentToken {
  id: string;
  userId: string;
  name: string;
  tokenHash: string;
  scopes: AgentScope[];
  createdAt: string;
  lastUsedAt?: string;
  expiresAt?: string;
  revokedAt?: string;
}

export interface AgentConnection {
  id: string;
  name: string;
  scopes: AgentScope[];
  createdAt: string;
  lastUsedAt?: string;
  expiresAt?: string;
}

export interface EventSchema {
  id: string;
  projectId: string;
  eventType: string;
  fields: Record<string, EventFieldDefinition>;
  version: number;
  status: "active";
  createdAt: string;
}

export interface NotificationSurface {
  id: string;
  projectId: string;
  eventType: string;
  type: "notification";
  titleTemplate: string;
  bodyTemplate: string;
  subtitleTemplate?: string;
  sound: string;
  group: string;
  priority: "normal" | "high";
  enabled: boolean;
  version: number;
  createdAt: string;
}

export const LIVE_SURFACE_TYPES = [
  "stats",
  "metrics",
  "segmented_progress",
  "progress",
  "alert",
  "timer",
] as const;

export type LiveSurfaceType = (typeof LIVE_SURFACE_TYPES)[number];

export interface LiveSurfaceAction {
  type: "open_url";
  title: string;
  url: string;
}

export interface LiveSurface {
  id: string;
  projectId: string;
  surfaceKey: string;
  type: LiveSurfaceType;
  title: string;
  subtitle?: string;
  content: Record<string, unknown>;
  action?: LiveSurfaceAction;
  displayOrder: number;
  version: number;
  createdAt: string;
  updatedAt: string;
}

export interface IngestToken {
  id: string;
  projectId: string;
  name: string;
  tokenHash: string;
  scope: "event:ingest";
  createdAt: string;
  lastUsedAt?: string;
  expiresAt?: string;
  revokedAt?: string;
}

export interface BellwireEvent {
  id: string;
  projectId: string;
  eventType: string;
  idempotencyKey: string;
  data: Record<string, unknown>;
  sensitiveFields?: string[];
  occurredAt: string;
  receivedAt: string;
  status: "accepted";
  readAt?: string;
}

export type DeliveryStatus = "queued" | "accepted_by_apns" | "failed";

export interface Delivery {
  id: string;
  eventId: string;
  deviceId: string;
  channel: "apns";
  status: DeliveryStatus;
  attemptCount: number;
  providerMessageId?: string;
  errorCode?: string;
  errorMessage?: string;
  queuedAt: string;
  sentAt?: string;
  updatedAt: string;
}

export interface EventListOptions {
  cursor?: string;
  limit: number;
  eventType?: string;
  unreadOnly?: boolean;
}

export interface EventListPage {
  events: BellwireEvent[];
  nextCursor?: string;
}

export interface DeliveryHealth {
  queued: number;
  accepted: number;
  failed: number;
  status: "healthy" | "degraded" | "idle";
}

export interface ValidationIssue {
  field: string;
  message: string;
}
