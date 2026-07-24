// SPDX-License-Identifier: AGPL-3.0-only
import type { Device } from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import { ApnsError, type ApnsNotification, type ApnsResult } from "./apns-client";

export interface PrivateWakeApnsSender {
  send(deviceToken: string, notification: ApnsNotification): Promise<ApnsResult>;
}

export type PrivateWakeApnsSenderFactory = (
  environment: Device["apnsEnvironment"],
) => PrivateWakeApnsSender;

export class PrivateWakeProcessor {
  constructor(
    private readonly repository: BellwireRepository,
    private readonly apns: PrivateWakeApnsSender | PrivateWakeApnsSenderFactory,
    private readonly now: () => Date = () => new Date(),
    private readonly leaseSeconds = 60,
  ) {}

  async process(wakeId: string): Promise<void> {
    const wake = await this.repository.getPrivateWake(wakeId);
    if (!wake?.reference) return;
    const project = await this.repository.getProject(wake.projectId);
    if (!project || project.status !== "active" || project.deliveryMode !== "private") return;

    const devices = (await this.repository.listDevices(project.userId))
      .filter((device) => device.pushEnabled);
    const existing = await this.repository.listPrivateWakeDeliveries(wake.id);
    const senders = new Map<Device["apnsEnvironment"], PrivateWakeApnsSender>();
    let shouldRetry = false;

    for (const device of devices) {
      const current = existing.find((delivery) => delivery.deviceId === device.id);
      const timestamp = this.now().toISOString();
      if (!current) {
        await this.repository.createPrivateWakeDeliveryIfAbsent({
            id: crypto.randomUUID(),
            wakeId: wake.id,
            deviceId: device.id,
            channel: "apns",
            status: "queued",
            attemptCount: 0,
            queuedAt: timestamp,
            updatedAt: timestamp,
          });
      }
    }

    const deliveries = await this.repository.listPrivateWakeDeliveries(wake.id);
    for (const snapshot of deliveries) {
      const device = devices.find((candidate) => candidate.id === snapshot.deviceId);
      if (!device) continue;
      const delivery = await this.repository.claimPrivateWakeDelivery(
        snapshot.id,
        this.now().toISOString(),
        this.leaseSeconds,
        3,
      );
      if (!delivery) {
        shouldRetry ||= snapshot.status === "queued" || (
          snapshot.status === "failed" &&
          snapshot.errorCode?.startsWith("retryable:") === true &&
          snapshot.attemptCount < 3
        );
        continue;
      }

      const sender = typeof this.apns === "function"
        ? senderForEnvironment(senders, device.apnsEnvironment, this.apns)
        : this.apns;
      try {
        const sent = await sender.send(device.apnsToken, {
          threadId: project.id,
          priority: wake.priority,
          signalId: wake.id,
          wakeId: wake.id,
          projectId: project.id,
          deliveryMode: "private",
          reference: wake.reference,
        });
        const completed = await this.repository.completeClaimedPrivateWakeDelivery({
          ...delivery,
          status: "accepted_by_apns",
          providerMessageId: sent.providerMessageId,
          sentAt: this.now().toISOString(),
          updatedAt: this.now().toISOString(),
        });
        shouldRetry ||= completed === undefined;
      } catch (error) {
        const apnsError = error instanceof ApnsError
          ? error
          : new ApnsError(0, "NetworkError", true);
        const retryable = apnsError.retryable && delivery.attemptCount < 3;
        const completed = await this.repository.completeClaimedPrivateWakeDelivery({
          ...delivery,
          status: "failed",
          errorCode: `${retryable ? "retryable" : "permanent"}:${apnsError.reason}`,
          errorMessage: apnsError.message.slice(0, 240),
          updatedAt: this.now().toISOString(),
        });
        shouldRetry ||= completed !== undefined && retryable;
      }
    }

    if (shouldRetry) throw new Error("One or more Private wake deliveries require retry");
    await this.repository.clearPrivateWakeReference(wake.id);
  }
}

function senderForEnvironment(
  senders: Map<Device["apnsEnvironment"], PrivateWakeApnsSender>,
  environment: Device["apnsEnvironment"],
  factory: PrivateWakeApnsSenderFactory,
): PrivateWakeApnsSender {
  const existing = senders.get(environment);
  if (existing) return existing;
  const sender = factory(environment);
  senders.set(environment, sender);
  return sender;
}
