// SPDX-License-Identifier: AGPL-3.0-only
import type { BellwireEvent } from "../domain/models";

export interface DeliveryQueueMessage {
  eventId: string;
}

export interface DeliveryDispatcher {
  enqueue(event: BellwireEvent): Promise<void>;
}

export class QueueDeliveryDispatcher implements DeliveryDispatcher {
  constructor(private readonly queue: Queue<DeliveryQueueMessage>) {}

  async enqueue(event: BellwireEvent): Promise<void> {
    await this.queue.send({ eventId: event.id }, { contentType: "json" });
  }
}
