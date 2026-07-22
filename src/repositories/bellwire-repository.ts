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

export interface CreateEventResult {
  event: BellwireEvent;
  created: boolean;
}

export interface CreateDeliveryResult {
  delivery: Delivery;
  created: boolean;
}

export interface BellwireRepository {
  createProject(project: Project): Promise<Project>;
  getProject(projectId: string): Promise<Project | undefined>;
  listProjects(userId: string): Promise<Project[]>;
  updateProject(project: Project): Promise<Project>;

  saveDevice(device: Device): Promise<Device>;
  getDevice(deviceId: string): Promise<Device | undefined>;
  listDevices(userId: string): Promise<Device[]>;
  deleteDevice(deviceId: string): Promise<void>;

  saveDeviceBinding(binding: DeviceBinding): Promise<DeviceBinding>;
  claimDeviceBinding(
    codeHash: string,
    token: Omit<AgentToken, "userId">,
    consumedAt: string,
  ): Promise<AgentToken | undefined>;

  saveAgentToken(token: AgentToken): Promise<AgentToken>;
  findAgentTokenByHash(tokenHash: string): Promise<AgentToken | undefined>;
  markAgentTokenUsed(tokenId: string, usedAt: string): Promise<void>;

  saveEventSchema(schema: EventSchema): Promise<EventSchema>;
  getEventSchema(
    projectId: string,
    eventType: string,
  ): Promise<EventSchema | undefined>;
  listEventSchemas(projectId: string): Promise<EventSchema[]>;

  saveNotificationSurface(surface: NotificationSurface): Promise<NotificationSurface>;
  getNotificationSurface(
    projectId: string,
    eventType: string,
  ): Promise<NotificationSurface | undefined>;
  listNotificationSurfaces(projectId: string): Promise<NotificationSurface[]>;

  saveLiveSurface(surface: LiveSurface): Promise<LiveSurface>;
  getLiveSurface(projectId: string, surfaceKey: string): Promise<LiveSurface | undefined>;
  listLiveSurfaces(projectId: string): Promise<LiveSurface[]>;
  deleteLiveSurface(surfaceId: string): Promise<void>;

  saveIngestToken(token: IngestToken): Promise<IngestToken>;
  listIngestTokens(projectId: string): Promise<IngestToken[]>;
  findIngestTokenByHash(
    projectId: string,
    tokenHash: string,
  ): Promise<IngestToken | undefined>;
  markIngestTokenUsed(tokenId: string, usedAt: string): Promise<void>;
  revokeIngestToken(tokenId: string, revokedAt: string): Promise<void>;

  consumeRateLimit(key: string, limit: number, windowSeconds: number): Promise<boolean>;
  createEventIfAbsent(event: BellwireEvent): Promise<CreateEventResult>;
  listEvents(projectId: string, options: EventListOptions): Promise<EventListPage>;
  getEvent(eventId: string): Promise<BellwireEvent | undefined>;
  markEventRead(eventId: string, readAt: string): Promise<void>;
  markAllEventsRead(projectIds: string[], readAt: string): Promise<number>;

  createDeliveryIfAbsent(delivery: Delivery): Promise<CreateDeliveryResult>;
  claimDelivery(
    deliveryId: string,
    claimedAt: string,
    leaseSeconds: number,
    maxAttempts: number,
  ): Promise<Delivery | undefined>;
  completeClaimedDelivery(delivery: Delivery): Promise<Delivery | undefined>;
  recordQueueUnavailable(
    expected: Delivery,
    failedAt: string,
    message: string,
  ): Promise<Delivery | undefined>;
  updateDelivery(delivery: Delivery): Promise<Delivery>;
  listDeliveries(eventId: string): Promise<Delivery[]>;
  getDeliveryHealth(projectId: string): Promise<DeliveryHealth>;
}
