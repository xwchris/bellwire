// SPDX-License-Identifier: Apache-2.0
export interface BellwireEnvironment {
  BELLWIRE_API_URL?: string;
  BELLWIRE_PROJECT_ID: string;
  BELLWIRE_INGEST_TOKEN: string;
}

export interface BellwireEvent {
  type: string;
  data: Record<string, unknown>;
  occurredAt: string;
}

export async function sendBellwireEvent(
  environment: BellwireEnvironment,
  idempotencyKey: string,
  event: BellwireEvent,
): Promise<void> {
  const apiURL = (environment.BELLWIRE_API_URL ?? "https://api.bellwire.app").replace(/\/$/u, "");
  const response = await fetch(
    `${apiURL}/v1/events/${encodeURIComponent(environment.BELLWIRE_PROJECT_ID)}`,
    {
      method: "POST",
      signal: AbortSignal.timeout(5_000),
      headers: {
        authorization: `Bearer ${environment.BELLWIRE_INGEST_TOKEN}`,
        "content-type": "application/json",
        "idempotency-key": idempotencyKey,
      },
      body: JSON.stringify(event),
    },
  );
  if (!response.ok) {
    throw new Error(`Bellwire request failed with HTTP ${response.status}`);
  }
}
