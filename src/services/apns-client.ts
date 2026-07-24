// SPDX-License-Identifier: AGPL-3.0-only
import { importPKCS8, SignJWT } from "jose";
import type { NotificationPrivacyMode } from "../domain/models";

export interface ApnsConfiguration {
  keyId: string;
  teamId: string;
  bundleId: string;
  urlScheme: string;
  privateKey: string;
  environment: "sandbox" | "production";
}

export interface ApnsNotification {
  title: string;
  body: string;
  subtitle?: string;
  sound: string;
  threadId: string;
  priority: "normal" | "high";
  eventId: string;
  projectId: string;
  logoUrl?: string;
  privacyMode: NotificationPrivacyMode;
  directNotificationRef?: string;
}

export interface ApnsResult {
  providerMessageId?: string;
}

export class ApnsError extends Error {
  constructor(
    readonly status: number,
    readonly reason: string,
    readonly retryable: boolean,
  ) {
    super(`APNs returned ${status}: ${reason}`);
    this.name = "ApnsError";
  }
}

export class ApnsClient {
  private signingKey?: CryptoKey;
  private providerToken?: { value: string; expiresAt: number };

  constructor(
    private readonly config: ApnsConfiguration,
    private readonly fetchImpl: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  async send(deviceToken: string, notification: ApnsNotification): Promise<ApnsResult> {
    const host = this.config.environment === "production"
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";
    const response = await this.fetchImpl(`${host}/3/device/${encodeURIComponent(deviceToken)}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.getProviderToken()}`,
        "apns-topic": this.config.bundleId,
        "apns-push-type": "alert",
        "apns-priority": notification.priority === "high" ? "10" : "5",
        "apns-collapse-id": notification.eventId,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: notification.privacyMode === "hosted_detailed"
            ? {
                title: notification.title,
                body: notification.body,
                ...(notification.subtitle ? { subtitle: notification.subtitle } : {}),
              }
            : {
                title: notification.title,
                "loc-key": "BELLWIRE_GENERIC_NOTIFICATION_BODY",
              },
          sound: notification.sound,
          "thread-id": notification.threadId,
          ...(notification.logoUrl || (
              notification.privacyMode === "local_enrichment"
              && notification.directNotificationRef
            )
            ? { "mutable-content": 1 }
            : {}),
        },
        eventId: notification.eventId,
        projectId: notification.projectId,
        deepLink: `${this.config.urlScheme}://events/${notification.eventId}`,
        bellwireNotificationMode: notification.privacyMode,
        ...(notification.privacyMode === "local_enrichment" && notification.directNotificationRef
          ? { directNotificationRef: notification.directNotificationRef }
          : {}),
        ...(notification.logoUrl ? { projectLogoUrl: notification.logoUrl } : {}),
      }),
    });
    if (!response.ok) {
      const error: { reason?: string } = await response
        .json<{ reason?: string }>()
        .catch(() => ({}));
      const reason = error.reason ?? "UnknownApnsError";
      if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") {
        this.providerToken = undefined;
      }
      throw new ApnsError(response.status, reason, isRetryable(response.status, reason));
    }
    return { providerMessageId: response.headers.get("apns-id") ?? undefined };
  }

  private async getProviderToken(): Promise<string> {
    const now = Date.now();
    if (this.providerToken && this.providerToken.expiresAt > now) return this.providerToken.value;
    this.signingKey ??= await importPKCS8(normalizePrivateKey(this.config.privateKey), "ES256");
    const value = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: this.config.keyId })
      .setIssuer(this.config.teamId)
      .setIssuedAt()
      .sign(this.signingKey);
    this.providerToken = { value, expiresAt: now + 50 * 60 * 1_000 };
    return value;
  }
}

function normalizePrivateKey(value: string): string {
  return value.replaceAll("\\n", "\n").trim();
}

function isRetryable(status: number, reason: string): boolean {
  return status === 429 || status >= 500 || reason === "ExpiredProviderToken";
}
