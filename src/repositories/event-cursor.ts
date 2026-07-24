// SPDX-License-Identifier: AGPL-3.0-only

export interface EventCursor {
  receivedAt: string;
  id: string;
}

export function encodeEventCursor(value: EventCursor): string {
  return btoa(JSON.stringify(value))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

export function decodeEventCursor(value: string): EventCursor {
  try {
    const padded = value.replaceAll("-", "+").replaceAll("_", "/")
      .padEnd(Math.ceil(value.length / 4) * 4, "=");
    const decoded = JSON.parse(atob(padded)) as unknown;
    if (typeof decoded !== "object" || decoded === null || Array.isArray(decoded)) {
      throw new Error("invalid");
    }
    const record = decoded as Record<string, unknown>;
    const receivedAt = record.receivedAt;
    const id = record.id;
    if (
      typeof receivedAt !== "string"
      || Number.isNaN(Date.parse(receivedAt))
      || typeof id !== "string"
      || !id
    ) {
      throw new Error("invalid");
    }
    return { receivedAt, id };
  } catch {
    throw new Error("Invalid Event cursor");
  }
}
