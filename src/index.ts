// SPDX-License-Identifier: AGPL-3.0-only
import { createApp } from "./app";
import type { BellwireRepository } from "./repositories/bellwire-repository";
import { InMemoryBellwireRepository } from "./repositories/in-memory-bellwire-repository";
import { SupabaseBellwireRepository } from "./repositories/supabase-bellwire-repository";
import { PrincipalAuthenticator } from "./security/authenticator";
import { BellwireService } from "./services/bellwire-service";
import { AppleAuthService, AppleTokenClient } from "./services/apple-auth-service";
import { ApnsClient } from "./services/apns-client";
import { DeliveryProcessor } from "./services/delivery-processor";
import {
  QueueDeliveryDispatcher,
  type DeliveryQueueMessage,
} from "./services/delivery-dispatcher";

export interface Env {
  APP_ENV: "development" | "staging" | "production";
  SUPABASE_URL?: string;
  SUPABASE_SERVICE_ROLE_KEY?: string;
  APPLE_SIGN_IN_KEY_ID?: string;
  APPLE_SIGN_IN_TEAM_ID?: string;
  APPLE_SIGN_IN_CLIENT_ID?: string;
  APPLE_SIGN_IN_PRIVATE_KEY?: string;
  APPLE_TOKEN_ENCRYPTION_KEY?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_BUNDLE_ID?: string;
  APP_URL_SCHEME?: string;
  APNS_PRIVATE_KEY?: string;
  APNS_ENVIRONMENT?: "sandbox" | "production";
  DELIVERY_QUEUE?: Queue<DeliveryQueueMessage>;
}

const developmentRepository = new InMemoryBellwireRepository();

export default {
  async fetch(request: Request, env: Env, executionContext: ExecutionContext): Promise<Response> {
    const repository = repositoryForEnv(env);
    const authenticator = new PrincipalAuthenticator(repository, {
      supabaseUrl: env.SUPABASE_URL,
      allowDevelopmentTokens: env.APP_ENV === "development" && !env.SUPABASE_URL,
    });
    const dispatcher = env.DELIVERY_QUEUE
      ? new QueueDeliveryDispatcher(env.DELIVERY_QUEUE)
      : undefined;
    const appleAuthService = createAppleAuthService(env, repository);
    const app = createApp({
      service: new BellwireService(repository, dispatcher, appleAuthService),
      authenticator,
    });
    return app.fetch(request, env, executionContext);
  },

  async queue(batch: MessageBatch<DeliveryQueueMessage>, env: Env): Promise<void> {
    const repository = repositoryForEnv(env);
    const processor = new DeliveryProcessor(repository, (environment) => new ApnsClient({
      keyId: requiredEnv(env.APNS_KEY_ID, "APNS_KEY_ID"),
      teamId: requiredEnv(env.APNS_TEAM_ID, "APNS_TEAM_ID"),
      bundleId: requiredEnv(env.APNS_BUNDLE_ID, "APNS_BUNDLE_ID"),
      urlScheme: env.APP_URL_SCHEME ?? "bellwire",
      privateKey: requiredEnv(env.APNS_PRIVATE_KEY, "APNS_PRIVATE_KEY"),
      environment,
    }));
    await Promise.all(
      batch.messages.map(async (message) => {
        try {
          await processor.process(message.body.eventId);
          message.ack();
        } catch (error) {
          console.error(
            "Delivery processing failed",
            error instanceof Error ? error.message : "Unknown error",
          );
          message.retry({ delaySeconds: Math.min(60 * 2 ** message.attempts, 900) });
        }
      }),
    );
  },
};

function repositoryForEnv(env: Env): BellwireRepository {
  if (env.SUPABASE_URL && env.SUPABASE_SERVICE_ROLE_KEY) {
    return new SupabaseBellwireRepository(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY);
  }
  if (env.APP_ENV !== "development") {
    throw new Error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
  }
  return developmentRepository;
}

function requiredEnv(value: string | undefined, name: string): string {
  if (!value) throw new Error(`${name} is required for delivery processing`);
  return value;
}

function createAppleAuthService(
  env: Env,
  repository: BellwireRepository,
): AppleAuthService | undefined {
  const values = [
    env.APPLE_SIGN_IN_KEY_ID,
    env.APPLE_SIGN_IN_TEAM_ID,
    env.APPLE_SIGN_IN_CLIENT_ID,
    env.APPLE_SIGN_IN_PRIVATE_KEY,
    env.APPLE_TOKEN_ENCRYPTION_KEY,
  ];
  if (values.every((value) => !value)) return undefined;
  const keyId = requiredEnv(env.APPLE_SIGN_IN_KEY_ID, "APPLE_SIGN_IN_KEY_ID");
  const teamId = requiredEnv(env.APPLE_SIGN_IN_TEAM_ID, "APPLE_SIGN_IN_TEAM_ID");
  const clientId = requiredEnv(env.APPLE_SIGN_IN_CLIENT_ID, "APPLE_SIGN_IN_CLIENT_ID");
  const privateKey = requiredEnv(env.APPLE_SIGN_IN_PRIVATE_KEY, "APPLE_SIGN_IN_PRIVATE_KEY");
  const encryptionKey = requiredEnv(
    env.APPLE_TOKEN_ENCRYPTION_KEY,
    "APPLE_TOKEN_ENCRYPTION_KEY",
  );
  return new AppleAuthService(
    repository,
    new AppleTokenClient({ keyId, teamId, clientId, privateKey }),
    encryptionKey,
  );
}
