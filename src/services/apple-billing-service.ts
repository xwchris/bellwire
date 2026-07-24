// SPDX-License-Identifier: AGPL-3.0-only
import {
  Environment,
  SignedDataVerifier,
  Status,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";

import type {
  AccountEntitlement,
  AppleTransactionRecord,
  EntitlementStatus,
  Principal,
} from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import type { ProductAnalytics } from "./product-analytics";

const PRODUCT_IDS = new Set([
  "app.bellwire.pro.monthly",
  "app.bellwire.pro.yearly",
]);

export class AppleBillingVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AppleBillingVerificationError";
  }
}

export interface AppleBillingVerifier {
  verifyTransaction(value: string): Promise<JWSTransactionDecodedPayload>;
  verifyNotification(value: string): Promise<ResponseBodyV2DecodedPayload>;
}

export class OfficialAppleBillingVerifier implements AppleBillingVerifier {
  private readonly verifiers: SignedDataVerifier[];

  constructor(configuration: {
    rootCertificatesBase64: string[];
    bundleId: string;
    appAppleId: number;
    enableOnlineChecks?: boolean;
  }) {
    if (configuration.rootCertificatesBase64.length === 0) {
      throw new Error("At least one Apple root certificate is required");
    }
    const roots = configuration.rootCertificatesBase64.map((value) =>
      Buffer.from(value.replace(/\s+/gu, ""), "base64"));
    const onlineChecks = configuration.enableOnlineChecks !== false;
    this.verifiers = [
      new SignedDataVerifier(
        roots,
        onlineChecks,
        Environment.PRODUCTION,
        configuration.bundleId,
        configuration.appAppleId,
      ),
      new SignedDataVerifier(
        roots,
        onlineChecks,
        Environment.SANDBOX,
        configuration.bundleId,
      ),
    ];
  }

  async verifyTransaction(value: string): Promise<JWSTransactionDecodedPayload> {
    return this.verifyWithFallback((verifier) => verifier.verifyAndDecodeTransaction(value));
  }

  async verifyNotification(value: string): Promise<ResponseBodyV2DecodedPayload> {
    return this.verifyWithFallback((verifier) => verifier.verifyAndDecodeNotification(value));
  }

  private async verifyWithFallback<T>(
    operation: (verifier: SignedDataVerifier) => Promise<T>,
  ): Promise<T> {
    let failure: unknown;
    for (const verifier of this.verifiers) {
      try {
        return await operation(verifier);
      } catch (error) {
        failure = error;
      }
    }
    throw new AppleBillingVerificationError(
      failure instanceof Error ? failure.message : "Apple signed data verification failed",
    );
  }
}

export class AppleBillingService {
  constructor(
    private readonly repository: BellwireRepository,
    private readonly verifier: AppleBillingVerifier,
    private readonly now: () => Date = () => new Date(),
    private readonly analytics?: ProductAnalytics,
  ) {}

  async submitTransaction(
    principal: Principal,
    signedTransaction: unknown,
    source: unknown = "sync",
  ): Promise<AccountEntitlement> {
    if (principal.kind !== "user") {
      throw new AppleBillingVerificationError("A signed-in user is required");
    }
    const value = readSignedValue(signedTransaction, "signedTransaction");
    const analyticsSource = readTransactionSource(source);
    const decoded = await this.verifier.verifyTransaction(value);
    const transaction = this.toTransaction(decoded, principal.userId);
    await this.repository.saveAppleTransaction(transaction);
    if (analyticsSource !== "sync") {
      await this.analytics?.capture(
        principal.userId,
        analyticsSource === "restore"
          ? "subscription_restored"
          : decoded.offerType === 1
            ? "trial_started"
            : "subscription_purchased",
        {
          plan: transaction.status === "active" || transaction.status === "grace" ? "pro" : "free",
          productId: transaction.productId,
          source: analyticsSource,
        },
      );
    }
    return this.repository.getAccountEntitlement(principal.userId, this.now().toISOString());
  }

  async processNotification(signedPayload: unknown): Promise<{ accepted: true; duplicate: boolean }> {
    const value = readSignedValue(signedPayload, "signedPayload");
    const decoded = await this.verifier.verifyNotification(value);
    const notificationUUID = requiredUUID(decoded.notificationUUID, "notificationUUID");
    const notificationType = requiredString(decoded.notificationType, "notificationType");
    const signedDate = requiredDate(decoded.signedDate, "signedDate");
    let transaction: AppleTransactionRecord | undefined;
    const signedTransaction = decoded.data?.signedTransactionInfo;
    if (signedTransaction) {
      const transactionPayload = await this.verifier.verifyTransaction(signedTransaction);
      const userId = requiredUUID(transactionPayload.appAccountToken, "appAccountToken");
      const forcedStatus = entitlementStatusFromApple(decoded.data?.status);
      transaction = this.toTransaction(transactionPayload, userId, forcedStatus);
    }
    if (transaction) {
      await this.repository.saveAppleTransaction(transaction);
    }
    const inserted = await this.repository.saveAppleNotificationReceipt(
      notificationUUID,
      notificationType,
      optionalString(decoded.subtype),
      signedDate,
    );
    if (!inserted) return { accepted: true, duplicate: true };
    if (transaction) {
      if (transaction.status === "expired") {
        await this.analytics?.capture(transaction.userId, "subscription_expired", {
          plan: "free",
          productId: transaction.productId,
        });
      } else if (transaction.status === "revoked") {
        await this.analytics?.capture(transaction.userId, "subscription_refunded", {
          plan: "free",
          productId: transaction.productId,
        });
      }
    }
    return { accepted: true, duplicate: false };
  }

  private toTransaction(
    payload: JWSTransactionDecodedPayload,
    expectedUserId: string,
    forcedStatus?: EntitlementStatus,
  ): AppleTransactionRecord {
    const userId = requiredUUID(payload.appAccountToken, "appAccountToken");
    if (userId !== expectedUserId.toLowerCase()) {
      throw new AppleBillingVerificationError(
        "The transaction appAccountToken does not match the signed-in account",
      );
    }
    const productId = requiredString(payload.productId, "productId");
    if (!PRODUCT_IDS.has(productId)) {
      throw new AppleBillingVerificationError("The transaction product is not a Bellwire Pro plan");
    }
    const environment = payload.environment;
    if (environment !== Environment.PRODUCTION && environment !== Environment.SANDBOX) {
      throw new AppleBillingVerificationError("The transaction environment is invalid");
    }
    const now = this.now().getTime();
    const expiresAt = optionalDate(payload.expiresDate);
    const revocationDate = optionalDate(payload.revocationDate);
    const status = forcedStatus
      ?? (revocationDate
        ? "revoked"
        : payload.expiresDate && payload.expiresDate > now
          ? "active"
          : "expired");
    return {
      transactionId: requiredString(payload.transactionId, "transactionId"),
      originalTransactionId: requiredString(
        payload.originalTransactionId,
        "originalTransactionId",
      ),
      userId,
      productId,
      environment,
      purchaseDate: requiredDate(payload.purchaseDate, "purchaseDate"),
      ...(expiresAt ? { expiresAt } : {}),
      ...(revocationDate ? { revocationDate } : {}),
      status,
      signedDate: requiredDate(payload.signedDate, "signedDate"),
      updatedAt: this.now().toISOString(),
    };
  }
}

function readTransactionSource(value: unknown): "purchase" | "restore" | "sync" {
  if (value === undefined) return "sync";
  if (value === "purchase" || value === "restore" || value === "sync") return value;
  throw new AppleBillingVerificationError("Transaction source is invalid");
}

function entitlementStatusFromApple(value: unknown): EntitlementStatus | undefined {
  switch (value) {
    case Status.ACTIVE: return "active";
    case Status.BILLING_RETRY:
    case Status.BILLING_GRACE_PERIOD: return "grace";
    case Status.REVOKED: return "revoked";
    case Status.EXPIRED: return "expired";
    default: return undefined;
  }
}

function readSignedValue(value: unknown, name: string): string {
  if (typeof value !== "string" || value.length < 100 || value.length > 100_000) {
    throw new AppleBillingVerificationError(`${name} is required`);
  }
  return value;
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value) {
    throw new AppleBillingVerificationError(`${name} is missing from verified Apple data`);
  }
  return value;
}

function optionalString(value: unknown): string | undefined {
  return typeof value === "string" && value ? value : undefined;
}

function requiredUUID(value: unknown, name: string): string {
  const normalized = requiredString(value, name).toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u.test(normalized)) {
    throw new AppleBillingVerificationError(`${name} must be a UUID`);
  }
  return normalized;
}

function requiredDate(value: unknown, name: string): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new AppleBillingVerificationError(`${name} is invalid`);
  }
  return new Date(value).toISOString();
}

function optionalDate(value: unknown): string | undefined {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? new Date(value).toISOString()
    : undefined;
}
