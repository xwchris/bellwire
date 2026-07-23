#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only

const supabaseURL = process.env.SUPABASE_URL ?? "https://cvyidqbjjkfzoxykkbea.supabase.co";
const supabasePublishableKey = process.env.SUPABASE_PUBLISHABLE_KEY
  ?? "sb_publishable_i4iVi9h_EXgBdkxsgOU_Rw_MLV2SIdg";
const apiURL = process.env.BELLWIRE_API_URL ?? "https://api.bellwire.app";

const serviceRoleKey = (await readStdin()).trim();
if (!(serviceRoleKey.startsWith("sb_secret_") || serviceRoleKey.startsWith("eyJ"))) {
  throw new Error("Pipe the Supabase secret key to stdin; it is never persisted or printed.");
}

const suffix = `${Date.now()}-${crypto.randomUUID().slice(0, 8)}`;
const email = `bellwire.smoke+${suffix}@example.com`;
const password = `Ap-${randomHex(24)}!`;
let userId;
let quotaKey;

try {
  const health = await requestJSON(`${apiURL}/health`, {}, 200);
  assert(health.status === "ok", "Worker health check did not report ok");

  const adminHeaders = {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    "content-type": "application/json",
  };
  const user = await requestJSON(`${supabaseURL}/auth/v1/admin/users`, {
    method: "POST",
    headers: adminHeaders,
    body: JSON.stringify({ email, password, email_confirm: true }),
  }, 200);
  userId = user.id;
  assert(typeof userId === "string", "Supabase did not return a temporary user ID");

  const auth = await requestJSON(`${supabaseURL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: supabasePublishableKey, "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  }, 200);
  const accessToken = auth.access_token;
  assert(typeof accessToken === "string", "Supabase did not return an access token");
  const userHeaders = {
    authorization: `Bearer ${accessToken}`,
    "content-type": "application/json",
  };

  const project = await requestJSON(`${apiURL}/v1/projects`, {
    method: "POST",
    headers: userHeaders,
    body: JSON.stringify({ name: "Live Smoke", category: "verification" }),
  }, 201);
  assert(typeof project.id === "string", "Project creation did not return an ID");

  const schema = await requestJSON(`${apiURL}/v1/projects/${project.id}/event-schemas`, {
    method: "POST",
    headers: userHeaders,
    body: JSON.stringify({
      eventType: "build.completed",
      fields: {
        branch: { type: "string", required: true },
        duration: { type: "number", required: true },
        internalNote: { type: "string", sensitive: true },
      },
      notification: {
        title: "Build completed",
        body: "{{ branch }} in {{ duration }}s",
      },
    }),
  }, 201);
  assert(schema.eventType === "build.completed", "Schema creation returned an unexpected type");

  const surfaceURL = `${apiURL}/v1/projects/${project.id}/surfaces/smoke-build`;
  const firstSurface = await requestJSON(surfaceURL, {
    method: "PUT",
    headers: userHeaders,
    body: JSON.stringify({
      type: "stats",
      title: "Build status",
      subtitle: "Live smoke",
      metrics: [
        { label: "Branch", value: "main" },
        { label: "State", value: "Healthy", color: "green" },
      ],
    }),
  }, 200);
  assert(firstSurface.type === "stats" && firstSurface.version === 1, "Initial Surface upsert failed");

  const updatedSurface = await requestJSON(surfaceURL, {
    method: "PUT",
    headers: userHeaders,
    body: JSON.stringify({
      type: "progress",
      title: "Build progress",
      percentage: 72,
    }),
  }, 200);
  assert(updatedSurface.type === "progress" && updatedSurface.version === 2, "Stable Surface update failed");

  const surfaces = await requestJSON(
    `${apiURL}/v1/projects/${project.id}/surfaces`,
    { headers: userHeaders },
    200,
  );
  assert(
    surfaces.surfaces?.some((item) => item.surfaceKey === "smoke-build" && item.version === 2),
    "Updated Surface was not visible",
  );

  const ingest = await requestJSON(`${apiURL}/v1/projects/${project.id}/ingest-tokens`, {
    method: "POST",
    headers: userHeaders,
    body: JSON.stringify({ name: "smoke" }),
  }, 201);
  assert(typeof ingest.token === "string" && ingest.token.startsWith("bw_live_"), "Ingest token was not issued");
  quotaKey = `${project.id}:${ingest.id}`;

  const idempotencyKey = `smoke-${suffix}`;
  const eventPayload = JSON.stringify({
    type: "build.completed",
    data: { branch: "main", duration: 42, internalNote: "redacted" },
    occurredAt: new Date().toISOString(),
  });
  const event = await requestJSON(`${apiURL}/v1/events/${project.id}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${ingest.token}`,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: eventPayload,
  }, 201);
  const duplicate = await requestJSON(`${apiURL}/v1/events/${project.id}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${ingest.token}`,
      "content-type": "application/json",
      "idempotency-key": idempotencyKey,
    },
    body: eventPayload,
  }, 200);
  assert(duplicate.deduplicated === true && duplicate.eventId === event.eventId, "Idempotency check failed");

  const inbox = await requestJSON(`${apiURL}/v1/inbox?limit=10`, { headers: userHeaders }, 200);
  assert(inbox.events?.some((item) => item.id === event.eventId), "Event was not visible in the inbox");

  const detail = await requestJSON(`${apiURL}/v1/events/${event.eventId}`, { headers: userHeaders }, 200);
  assert(detail.sensitiveFields?.includes("internalNote"), "Sensitive field metadata was not preserved");
  await requestJSON(`${apiURL}/v1/events/${event.eventId}/read`, {
    method: "POST",
    headers: userHeaders,
  }, 200);

  const binding = await requestJSON(`${apiURL}/v1/device-bindings`, {
    method: "POST",
    headers: userHeaders,
  }, 201);
  const agent = await requestJSON(`${apiURL}/v1/device-bindings/confirm`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ code: binding.code, name: "Live Smoke Agent" }),
  }, 201);
  const agentProjects = await requestJSON(`${apiURL}/v1/projects`, {
    headers: { authorization: `Bearer ${agent.token}` },
  }, 200);
  assert(agentProjects.projects?.some((item) => item.id === project.id), "Agent binding could not read the project");

  const healthSummary = await requestJSON(
    `${apiURL}/v1/projects/${project.id}/delivery-health`,
    { headers: userHeaders },
    200,
  );
  assert(healthSummary.status === "idle", "Delivery health should be idle without a registered device");

  const devicePayload = JSON.stringify({
    name: "Smoke iPhone",
    apnsToken: "a".repeat(64),
    appVersion: "1.0",
  });
  const firstDevice = await requestJSON(`${apiURL}/v1/devices`, {
    method: "POST",
    headers: userHeaders,
    body: devicePayload,
  }, 201);
  const sameDevice = await requestJSON(`${apiURL}/v1/devices`, {
    method: "POST",
    headers: userHeaders,
    body: devicePayload,
  }, 201);
  assert(firstDevice.id === sameDevice.id, "Re-registering an APNs token changed its device ID");
  await requestJSON(`${apiURL}/v1/devices/${firstDevice.id}`, {
    method: "DELETE",
    headers: userHeaders,
  }, 204);
  await requestJSON(surfaceURL, {
    method: "DELETE",
    headers: userHeaders,
  }, 204);

  console.log(JSON.stringify({
    ok: true,
    worker: "healthy",
    supabaseAuth: "verified",
    projectLifecycle: "verified",
    liveSurfaceUpsert: "verified",
    eventIdempotency: "verified",
    inboxAndDetail: "verified",
    agentBinding: "verified",
    deviceUpsert: "verified",
    deliveryWithoutDevice: "idle",
  }, null, 2));
} finally {
  const cleanupHeaders = {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
  };
  if (quotaKey) {
    await fetch(
      `${supabaseURL}/rest/v1/ingest_rate_limits?key=eq.${encodeURIComponent(quotaKey)}`,
      { method: "DELETE", headers: cleanupHeaders },
    );
  }
  if (userId) {
    await fetch(`${supabaseURL}/auth/v1/admin/users/${userId}`, {
      method: "DELETE",
      headers: cleanupHeaders,
    });
  }
}

async function requestJSON(url, init, expectedStatus) {
  const response = await fetch(url, init);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    body = { message: text };
  }
  if (response.status !== expectedStatus) {
    throw new Error(`${init.method ?? "GET"} ${new URL(url).pathname} returned ${response.status}: ${safeError(body)}`);
  }
  return body;
}

function safeError(body) {
  const candidate = body?.error?.message ?? body?.message ?? body?.msg ?? "Unexpected response";
  return String(candidate).slice(0, 240);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function randomHex(length) {
  const bytes = crypto.getRandomValues(new Uint8Array(Math.ceil(length / 2)));
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("").slice(0, length);
}

async function readStdin() {
  let value = "";
  for await (const chunk of process.stdin) value += chunk;
  return value;
}
