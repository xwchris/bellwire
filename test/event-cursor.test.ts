// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from "vitest";

import type { BellwireEvent, Project } from "../src/domain/models";
import { decodeEventCursor, encodeEventCursor } from "../src/repositories/event-cursor";
import { InMemoryBellwireRepository } from "../src/repositories/in-memory-bellwire-repository";

describe("opaque Event cursors", () => {
  it("round-trips without exposing a raw timestamp", () => {
    const value = {
      receivedAt: "2026-07-25T10:00:00.000Z",
      id: "11111111-1111-4111-8111-111111111111",
    };
    const cursor = encodeEventCursor(value);
    expect(cursor).not.toContain("2026-07-25");
    expect(decodeEventCursor(cursor)).toEqual(value);
    expect(() => decodeEventCursor("not-a-cursor")).toThrow("Invalid Event cursor");
  });

  it("does not skip or duplicate Events sharing the same received timestamp", async () => {
    const repository = new InMemoryBellwireRepository();
    const project = await repository.createProject(hostedProject());
    const receivedAt = "2026-07-25T10:00:00.000Z";
    for (const id of [
      "11111111-1111-4111-8111-111111111111",
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
    ]) {
      await repository.acceptHostedEvent(event(project.id, id, receivedAt), "disabled");
    }

    const first = await repository.listEvents(project.id, { limit: 2 });
    const second = await repository.listEvents(project.id, {
      limit: 2,
      cursor: first.nextCursor,
    });
    expect(first.events.map((value) => value.id)).toEqual([
      "33333333-3333-4333-8333-333333333333",
      "22222222-2222-4222-8222-222222222222",
    ]);
    expect(second.events.map((value) => value.id)).toEqual([
      "11111111-1111-4111-8111-111111111111",
    ]);
  });
});

function hostedProject(): Project {
  return {
    id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    userId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    name: "Hosted",
    slug: "hosted",
    icon: "bell",
    displayOrder: 0,
    category: "automation",
    status: "active",
    deliveryMode: "hosted",
    endpoint: "/v1/events/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    createdAt: "2026-07-25T10:00:00.000Z",
    updatedAt: "2026-07-25T10:00:00.000Z",
  };
}

function event(projectId: string, id: string, receivedAt: string): BellwireEvent {
  return {
    id,
    projectId,
    eventType: "test.event",
    idempotencyKeyHash: id.replaceAll("-", "").padEnd(64, "0"),
    data: { id },
    sensitiveFields: [],
    occurredAt: receivedAt,
    receivedAt,
    status: "accepted",
  };
}
