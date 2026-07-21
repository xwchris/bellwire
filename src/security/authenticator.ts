import { createRemoteJWKSet, jwtVerify } from "jose";

import { AGENT_SCOPES, type Principal } from "../domain/models";
import type { BellwireRepository } from "../repositories/bellwire-repository";
import { hashSecret, readBearerToken } from "./tokens";

export class AuthenticationError extends Error {
  constructor(
    readonly status: 401 | 403,
    readonly code: "UNAUTHORIZED" | "FORBIDDEN",
    message: string,
  ) {
    super(message);
    this.name = "AuthenticationError";
  }
}

export interface Authenticator {
  authenticate(authorization: string | undefined): Promise<Principal>;
}

export class PrincipalAuthenticator implements Authenticator {
  private readonly issuer?: string;
  private readonly jwks?: ReturnType<typeof createRemoteJWKSet>;

  constructor(
    private readonly repository: BellwireRepository,
    options: { supabaseUrl?: string; allowDevelopmentTokens?: boolean },
  ) {
    this.allowDevelopmentTokens = options.allowDevelopmentTokens === true;
    if (options.supabaseUrl) {
      const baseUrl = options.supabaseUrl.replace(/\/$/u, "");
      this.issuer = `${baseUrl}/auth/v1`;
      this.jwks = createRemoteJWKSet(new URL(`${this.issuer}/.well-known/jwks.json`));
    }
  }

  private readonly allowDevelopmentTokens: boolean;

  async authenticate(authorization: string | undefined): Promise<Principal> {
    const token = readBearerToken(authorization);
    if (!token) throw unauthorized();

    if (token.startsWith("bw_agent_")) {
      const stored = await this.repository.findAgentTokenByHash(await hashSecret(token));
      if (!stored) throw unauthorized();
      await this.repository.markAgentTokenUsed(stored.id, new Date().toISOString());
      return {
        kind: "agent",
        userId: stored.userId,
        tokenId: stored.id,
        scopes: stored.scopes,
      };
    }

    if (this.allowDevelopmentTokens && token.startsWith("bw_dev_")) {
      const userId = token.slice("bw_dev_".length).trim();
      if (!userId) throw unauthorized();
      return { kind: "user", userId, scopes: [...AGENT_SCOPES] };
    }

    if (!this.jwks || !this.issuer) throw unauthorized();
    try {
      const verified = await jwtVerify(token, this.jwks, {
        issuer: this.issuer,
        audience: "authenticated",
      });
      const userId = verified.payload.sub;
      if (!userId) throw unauthorized();
      return { kind: "user", userId, scopes: [...AGENT_SCOPES] };
    } catch (error) {
      if (error instanceof AuthenticationError) throw error;
      throw unauthorized();
    }
  }
}

export class StaticAuthenticator implements Authenticator {
  constructor(private readonly principal: Principal) {}

  async authenticate(): Promise<Principal> {
    return structuredClone(this.principal);
  }
}

export function requireScope(principal: Principal, scope: Principal["scopes"][number]): void {
  if (principal.kind === "agent" && !principal.scopes.includes(scope)) {
    throw new AuthenticationError(403, "FORBIDDEN", `Missing required scope: ${scope}`);
  }
}

function unauthorized(): AuthenticationError {
  return new AuthenticationError(401, "UNAUTHORIZED", "Authentication is required");
}
