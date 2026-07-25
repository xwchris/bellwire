// SPDX-License-Identifier: AGPL-3.0-only
import type { Device } from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import { ApnsError, type ApnsNotification, type ApnsResult } from "./apns-client";

export interface ModeRequestApnsSender {
  send(deviceToken: string, notification: ApnsNotification): Promise<ApnsResult>;
}

export type ModeRequestApnsSenderFactory = (
  environment: Device["apnsEnvironment"],
) => ModeRequestApnsSender;

export class ModeRequestNotificationProcessor {
  constructor(
    private readonly repository: BellwireRepository,
    private readonly apns: ModeRequestApnsSender | ModeRequestApnsSenderFactory,
  ) {}

  async process(requestId: string, userId: string): Promise<void> {
    const request = (await this.repository.listDeliveryModeChangeRequests(userId, "pending"))
      .find((candidate) => candidate.id === requestId);
    if (!request) return;

    const project = await this.repository.getProject(request.projectId);
    if (!project || project.userId !== userId || project.status !== "active") return;

    const devices = (await this.repository.listDevices(userId))
      .filter((device) => device.pushEnabled);
    const senders = new Map<Device["apnsEnvironment"], ModeRequestApnsSender>();
    let shouldRetry = false;

    for (const device of devices) {
      const sender = typeof this.apns === "function"
        ? senderForEnvironment(senders, device.apnsEnvironment, this.apns)
        : this.apns;
      try {
        await sender.send(device.apnsToken, {
          title: "Approval needed",
          body: `${project.name} requests ${request.toMode === "private" ? "Private" : "Hosted"} delivery`,
          sound: "default",
          threadId: `mode-request:${project.id}`,
          priority: "high",
          signalId: request.id,
          projectId: project.id,
          deliveryMode: project.deliveryMode,
          modeRequest: {
            id: request.id,
            toMode: request.toMode,
          },
        });
      } catch (error) {
        const apnsError = error instanceof ApnsError
          ? error
          : new ApnsError(0, "NetworkError", true);
        if (["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].includes(apnsError.reason)) {
          await this.repository.deleteDevice(device.id);
        } else {
          shouldRetry ||= apnsError.retryable;
        }
      }
    }

    if (shouldRetry) throw new Error("Mode request notification requires retry");
  }
}

function senderForEnvironment(
  senders: Map<Device["apnsEnvironment"], ModeRequestApnsSender>,
  environment: Device["apnsEnvironment"],
  factory: ModeRequestApnsSenderFactory,
): ModeRequestApnsSender {
  const existing = senders.get(environment);
  if (existing) return existing;
  const sender = factory(environment);
  senders.set(environment, sender);
  return sender;
}
