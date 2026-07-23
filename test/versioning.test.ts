// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from "vitest";

import type { EventSchema, LiveSurface, NotificationSurface, Project } from "../src/domain/models";
import { InMemoryBellwireRepository } from "../src/repositories/in-memory-bellwire-repository";

const timestamp = "2026-07-21T08:00:00.000Z";

const project: Project = {
  id: "version-project",
  userId: "version-user",
  name: "Version project",
  slug: "version-project",
  icon: "bolt",
  displayOrder: 0,
  category: "test",
  status: "active",
  endpoint: "/v1/events/version-project",
  createdAt: timestamp,
  updatedAt: timestamp,
};

describe("atomic configuration versioning", () => {
  it("assigns unique consecutive versions under concurrent in-memory saves", async () => {
    const repository = new InMemoryBellwireRepository();
    await repository.createProject(project);

    const schemas = await Promise.all(Array.from({ length: 8 }, (_, index) =>
      repository.saveEventSchema({
        id: `schema-${index}`,
        projectId: project.id,
        eventType: "build.finished",
        fields: { result: { type: "string" } },
        version: 1,
        status: "active",
        createdAt: timestamp,
      } satisfies EventSchema)));
    const surfaces = await Promise.all(Array.from({ length: 8 }, (_, index) =>
      repository.saveNotificationSurface({
        id: `surface-${index}`,
        projectId: project.id,
        eventType: "build.finished",
        type: "notification",
        titleTemplate: `Build ${index}`,
        bodyTemplate: "Finished",
        sound: "default",
        group: "build",
        priority: "normal",
        enabled: true,
        version: 1,
        createdAt: timestamp,
      } satisfies NotificationSurface)));
    const liveSurfaces = await Promise.all(Array.from({ length: 8 }, (_, index) =>
      repository.saveLiveSurface({
        id: `live-${index}`,
        projectId: project.id,
        surfaceKey: "build-status",
        type: "progress",
        title: "Build",
        content: { percentage: index * 10 },
        displayOrder: 0,
        version: 1,
        createdAt: timestamp,
        updatedAt: `2026-07-21T08:00:0${index}.000Z`,
      } satisfies LiveSurface)));

    expect(schemas.map(({ version }) => version)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(surfaces.map(({ version }) => version)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(liveSurfaces.map(({ version }) => version)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(new Set(liveSurfaces.map(({ id }) => id))).toEqual(new Set(["live-0"]));
    expect(await repository.getLiveSurface(project.id, "build-status"))
      .toMatchObject({ version: 8, content: { percentage: 70 } });
  });
});
