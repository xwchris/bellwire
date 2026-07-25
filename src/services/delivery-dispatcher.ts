// SPDX-License-Identifier: AGPL-3.0-only
import type {
  BellwireEvent,
  DeliveryModeChangeRequest,
  PrivateWake,
  Project,
} from "../domain/models";

export type DeliveryQueueMessage =
  | { kind: "hosted_event"; eventId: string }
  | { kind: "private_wake"; wakeId: string }
  | { kind: "mode_request"; requestId: string; userId: string };

export interface DeliveryDispatcher {
  enqueue(event: BellwireEvent): Promise<void>;
  enqueuePrivateWake(wake: PrivateWake): Promise<void>;
  enqueueModeRequest(request: DeliveryModeChangeRequest, project: Project): Promise<void>;
}

export class QueueDeliveryDispatcher implements DeliveryDispatcher {
  constructor(private readonly queue: Queue<DeliveryQueueMessage>) {}

  async enqueue(event: BellwireEvent): Promise<void> {
    await this.queue.send(
      { kind: "hosted_event", eventId: event.id },
      { contentType: "json" },
    );
  }

  async enqueuePrivateWake(wake: PrivateWake): Promise<void> {
    await this.queue.send(
      { kind: "private_wake", wakeId: wake.id },
      { contentType: "json" },
    );
  }

  async enqueueModeRequest(
    request: DeliveryModeChangeRequest,
    project: Project,
  ): Promise<void> {
    await this.queue.send(
      { kind: "mode_request", requestId: request.id, userId: project.userId },
      { contentType: "json" },
    );
  }
}
