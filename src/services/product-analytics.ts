// SPDX-License-Identifier: AGPL-3.0-only

export const PRODUCT_EVENTS = [
  "pricing_viewed",
  "paywall_viewed",
  "trial_started",
  "subscription_purchased",
  "subscription_restored",
  "subscription_expired",
  "subscription_refunded",
  "quota_warning_80",
  "quota_reached_100",
  "quota_grace_used",
  "quota_rejected",
  "upgrade_clicked",
  "subscription_managed",
] as const;

export type ProductEvent = (typeof PRODUCT_EVENTS)[number];
export type AnalyticsProperty = string | number | boolean;
export type AnalyticsProperties = Record<string, AnalyticsProperty>;

const ALLOWED_PROPERTIES = new Set([
  "plan",
  "productId",
  "deliveryMode",
  "usagePercent",
  "projectCount",
  "deviceCount",
  "storefront",
  "appVersion",
  "source",
]);

export interface ProductAnalytics {
  capture(
    distinctId: string,
    event: ProductEvent,
    properties?: AnalyticsProperties,
  ): Promise<void>;
}

export class PostHogProductAnalytics implements ProductAnalytics {
  constructor(
    private readonly projectKey: string,
    private readonly host = "https://us.i.posthog.com",
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async capture(
    distinctId: string,
    event: ProductEvent,
    properties: AnalyticsProperties = {},
  ): Promise<void> {
    const safeProperties = validateAnalyticsProperties(properties);
    try {
      const response = await this.fetchImpl(`${this.host.replace(/\/$/u, "")}/capture/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          api_key: this.projectKey,
          event,
          properties: {
            distinct_id: distinctId,
            ...safeProperties,
          },
        }),
        signal: AbortSignal.timeout(1_500),
      });
      if (!response.ok) console.error("Product analytics request failed", response.status);
    } catch (error) {
      console.error(
        "Product analytics unavailable",
        error instanceof Error ? error.message : "Unknown error",
      );
    }
  }
}

export function readProductEvent(value: unknown): ProductEvent | undefined {
  return typeof value === "string" && PRODUCT_EVENTS.includes(value as ProductEvent)
    ? value as ProductEvent
    : undefined;
}

export function validateAnalyticsProperties(value: unknown): AnalyticsProperties {
  if (value === undefined) return {};
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("Analytics properties must be an object");
  }
  const result: AnalyticsProperties = {};
  for (const [key, property] of Object.entries(value)) {
    if (!ALLOWED_PROPERTIES.has(key)) throw new Error(`Analytics property is not allowed: ${key}`);
    if (
      typeof property !== "string" &&
      typeof property !== "number" &&
      typeof property !== "boolean"
    ) {
      throw new Error(`Analytics property has an invalid type: ${key}`);
    }
    result[key] = property;
  }
  return result;
}
