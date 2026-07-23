// SPDX-License-Identifier: AGPL-3.0-only
import type {
  BellwireEvent,
  EventFieldDefinition,
  NotificationSurface,
  Project,
} from "../domain/models";

export interface RenderedNotification {
  title: string;
  body: string;
  subtitle?: string;
  sound: string;
  threadId: string;
  priority: "normal" | "high";
  logoUrl?: string;
}

export function renderNotification(
  project: Project,
  event: BellwireEvent,
  surface: NotificationSurface,
  fields: Record<string, EventFieldDefinition>,
): RenderedNotification {
  const safeData = Object.fromEntries(
    Object.entries(event.data).filter(([key]) => fields[key]?.sensitive !== true),
  );
  const render = (template: string) => renderTemplate(template, safeData);
  const title = render(surface.titleTemplate).trim();
  const body = render(surface.bodyTemplate).trim();
  const subtitle = surface.subtitleTemplate ? render(surface.subtitleTemplate).trim() : undefined;
  return {
    title: truncate(title || humanize(event.eventType), 80),
    body: truncate(body || `New event from ${project.name}`, 180),
    ...(subtitle ? { subtitle: truncate(subtitle, 80) } : {}),
    sound: surface.sound,
    threadId: surface.group,
    priority: surface.priority,
    ...(project.logoUrl ? { logoUrl: project.logoUrl } : {}),
  };
}

function renderTemplate(template: string, data: Record<string, unknown>): string {
  return template.replace(
    /\{\{\s*([A-Za-z][A-Za-z0-9_]*)(?:\s*\|\s*default:\s*(['"])(.*?)\2)?\s*\}\}/gu,
    (_match, key: string, _quote: string | undefined, fallback: string | undefined) => {
      const value = data[key];
      if (value === undefined || value === null || value === "") return fallback ?? "";
      if (typeof value === "number") {
        return new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(value);
      }
      if (typeof value === "boolean") return value ? "Yes" : "No";
      return String(value);
    },
  );
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  return `${value.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

function humanize(value: string): string {
  return value
    .split(/[._-]/u)
    .filter(Boolean)
    .map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`)
    .join(" ");
}
