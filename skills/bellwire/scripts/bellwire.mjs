#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const DEFAULT_API_URL = "https://api.bellwire.app";
const FIELD_TYPES = new Set(["string", "number", "boolean", "datetime", "url", "enum"]);
const SURFACE_TYPES = new Set(["stats", "metrics", "segmented_progress", "progress", "alert", "timer"]);
const SURFACE_COLORS = new Set(["lime", "green", "cyan", "blue", "purple", "magenta", "red", "orange", "yellow", "gray"]);

const { command, options } = parseArguments(process.argv.slice(2));

if (!command || options.help) {
  printHelp();
  process.exit(options.help ? 0 : 1);
}

try {
  const result = await run(command, options);
  printResult(result, options.json === true);
} catch (error) {
  const message = error instanceof Error ? error.message : "Unknown Bellwire error";
  process.stderr.write(`Bellwire: ${message}\n`);
  process.exit(1);
}

async function run(selectedCommand, args) {
  switch (selectedCommand) {
    case "bind": {
      const code = required(args, "code");
      if (!/^\d{6}$/u.test(code)) throw new Error("--code must contain exactly six digits");
      return apiRequest("/v1/device-bindings/confirm", {
        method: "POST",
        body: { code, name: args.name ?? "Codex" },
        authenticated: false,
      });
    }
    case "list-projects":
      return apiRequest("/v1/projects");
    case "create-project":
      if (args["logo-url"]) validateLogoUrl(args["logo-url"]);
      return apiRequest("/v1/projects", {
        method: "POST",
        body: {
          name: required(args, "name"),
          ...(args.icon ? { icon: args.icon } : {}),
          ...(args["logo-url"] ? { logoUrl: args["logo-url"] } : {}),
          ...(args.category ? { category: args.category } : {}),
        },
      });
    case "update-project": {
      const projectId = required(args, "project");
      if (args["logo-url"] && args["clear-logo"]) {
        throw new Error("Use either --logo-url or --clear-logo, not both");
      }
      if (args["logo-url"]) validateLogoUrl(args["logo-url"]);
      const body = {
        ...(args.name ? { name: args.name } : {}),
        ...(args.icon ? { icon: args.icon } : {}),
        ...(args.category ? { category: args.category } : {}),
        ...(args.status ? { status: args.status } : {}),
        ...(args["logo-url"] ? { logoUrl: args["logo-url"] } : {}),
        ...(args["clear-logo"] ? { logoUrl: null } : {}),
      };
      if (Object.keys(body).length === 0) throw new Error("Provide at least one project field to update");
      return apiRequest(`/v1/projects/${encodeURIComponent(projectId)}`, { method: "PATCH", body });
    }
    case "validate-spec": {
      const spec = await readJsonFile(required(args, "file"));
      validateSpec(spec);
      return { valid: true, eventType: spec.eventType };
    }
    case "create-schema": {
      const projectId = required(args, "project");
      const spec = await readJsonFile(required(args, "file"));
      validateSpec(spec);
      return apiRequest(`/v1/projects/${encodeURIComponent(projectId)}/event-schemas`, {
        method: "POST",
        body: spec,
      });
    }
    case "create-token":
      return apiRequest(`/v1/projects/${encodeURIComponent(required(args, "project"))}/ingest-tokens`, {
        method: "POST",
        body: { name: args.name ?? "production" },
      });
    case "validate-surface": {
      const surface = await readJsonFile(required(args, "file"));
      validateSurface(surface);
      return { valid: true, type: surface.type };
    }
    case "upsert-surface": {
      const projectId = required(args, "project");
      const surfaceKey = required(args, "key");
      if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/u.test(surfaceKey)) {
        throw new Error("--key must use lowercase letters, digits, dots, dashes, or underscores");
      }
      const surface = await readJsonFile(required(args, "file"));
      validateSurface(surface);
      return apiRequest(
        `/v1/projects/${encodeURIComponent(projectId)}/surfaces/${encodeURIComponent(surfaceKey)}`,
        { method: "PUT", body: surface },
      );
    }
    case "list-surfaces": {
      const projectId = args.project;
      return apiRequest(projectId
        ? `/v1/projects/${encodeURIComponent(projectId)}/surfaces`
        : "/v1/surfaces");
    }
    case "delete-surface":
      return apiRequest(
        `/v1/projects/${encodeURIComponent(required(args, "project"))}/surfaces/${encodeURIComponent(required(args, "key"))}`,
        { method: "DELETE" },
      );
    case "send-test": {
      const event = await readJsonFile(required(args, "file"));
      validateTestEvent(event);
      return apiRequest(`/v1/projects/${encodeURIComponent(required(args, "project"))}/events/test`, {
        method: "POST",
        body: event,
      });
    }
    case "event":
      return apiRequest(`/v1/events/${encodeURIComponent(required(args, "event"))}`);
    case "health":
      return apiRequest(`/v1/projects/${encodeURIComponent(required(args, "project"))}/delivery-health`);
    default:
      throw new Error(`Unknown command: ${selectedCommand}`);
  }
}

async function apiRequest(path, init = {}) {
  const baseUrl = (process.env.BELLWIRE_API_URL || DEFAULT_API_URL).replace(/\/$/u, "");
  const headers = { accept: "application/json" };
  if (init.authenticated !== false) {
    const token = process.env.BELLWIRE_AGENT_TOKEN?.trim();
    if (!token) throw new Error("BELLWIRE_AGENT_TOKEN is required for this command");
    headers.authorization = `Bearer ${token}`;
  }
  if (init.body !== undefined) headers["content-type"] = "application/json";
  const response = await fetch(`${baseUrl}${path}`, {
    method: init.method ?? "GET",
    headers,
    signal: AbortSignal.timeout(15_000),
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  const text = await response.text();
  const data = text ? safeJson(text) : {};
  if (!response.ok) {
    const code = data?.error?.code ? `${data.error.code}: ` : "";
    const message = data?.error?.message ?? `HTTP ${response.status}`;
    throw new Error(`${code}${message}`);
  }
  return data;
}

function parseArguments(argv) {
  const parsed = {};
  let selectedCommand;
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!selectedCommand && !item.startsWith("--")) {
      selectedCommand = item;
      continue;
    }
    if (!item.startsWith("--")) throw new Error(`Unexpected argument: ${item}`);
    const key = item.slice(2);
    if (key === "json" || key === "help" || key === "clear-logo") {
      parsed[key] = true;
      continue;
    }
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for --${key}`);
    parsed[key] = value;
    index += 1;
  }
  return { command: selectedCommand, options: parsed };
}

async function readJsonFile(path) {
  const content = await readFile(path, "utf8");
  return safeJson(content, `Invalid JSON in ${path}`);
}

function safeJson(value, fallback = "Server returned invalid JSON") {
  try {
    return JSON.parse(value);
  } catch {
    throw new Error(fallback);
  }
}

function validateSpec(value) {
  if (!isRecord(value)) throw new Error("Event Spec must be a JSON object");
  if (typeof value.eventType !== "string" || !/^[a-z0-9]+(?:\.[a-z0-9]+)*$/u.test(value.eventType)) {
    throw new Error("eventType must be a dotted event name such as payment.success");
  }
  if (!isRecord(value.fields) || Object.keys(value.fields).length === 0) {
    throw new Error("fields must contain at least one field definition");
  }
  for (const [name, rawDefinition] of Object.entries(value.fields)) {
    if (!/^[A-Za-z][A-Za-z0-9_]*$/u.test(name)) throw new Error(`Invalid field name: ${name}`);
    if (!isRecord(rawDefinition) || !FIELD_TYPES.has(rawDefinition.type)) {
      throw new Error(`Unsupported type for field ${name}`);
    }
    if (rawDefinition.required !== undefined && typeof rawDefinition.required !== "boolean") {
      throw new Error(`required must be boolean for field ${name}`);
    }
    if (rawDefinition.sensitive !== undefined && typeof rawDefinition.sensitive !== "boolean") {
      throw new Error(`sensitive must be boolean for field ${name}`);
    }
    if (
      rawDefinition.type === "enum" &&
      (!Array.isArray(rawDefinition.values) || rawDefinition.values.length === 0 ||
        rawDefinition.values.some((item) => !nonEmpty(item)))
    ) {
      throw new Error(`Enum field ${name} requires values`);
    }
  }
  if (value.notification !== undefined) {
    if (!isRecord(value.notification)) throw new Error("notification must be an object");
    if (!nonEmpty(value.notification.title) || !nonEmpty(value.notification.body)) {
      throw new Error("notification.title and notification.body are required");
    }
    if (value.notification.title.length > 240 || value.notification.body.length > 240) {
      throw new Error("notification title and body must be at most 240 characters");
    }
    if (value.notification.priority !== undefined && !["normal", "high"].includes(value.notification.priority)) {
      throw new Error("notification.priority must be normal or high");
    }
    const template = `${value.notification.title} ${value.notification.body} ${value.notification.subtitle ?? ""}`;
    const tokenPattern = /\{\{\s*([A-Za-z][A-Za-z0-9_]*)(?:\s*\|\s*default:\s*(['"])(.*?)\2)?\s*\}\}/gu;
    const matches = [...template.matchAll(tokenPattern)];
    if (template.replace(tokenPattern, "").includes("{{") || template.replace(tokenPattern, "").includes("}}")) {
      throw new Error("notification contains unsupported template syntax");
    }
    for (const match of matches) {
      const field = match[1];
      if (!value.fields[field]) throw new Error(`Notification references unknown field ${field}`);
      if (value.fields[field].sensitive === true) throw new Error(`Notification references sensitive field ${field}`);
    }
  }
}

function validateTestEvent(value) {
  if (!isRecord(value) || !nonEmpty(value.type) || !isRecord(value.data) || !nonEmpty(value.occurredAt)) {
    throw new Error("Test event requires type, data, and occurredAt");
  }
  if (Number.isNaN(Date.parse(value.occurredAt))) throw new Error("occurredAt must be an ISO datetime");
}

function validateSurface(value) {
  if (!isRecord(value) || !SURFACE_TYPES.has(value.type)) {
    throw new Error(`Surface type must be one of: ${[...SURFACE_TYPES].join(", ")}`);
  }
  bounded(value.title, "title", 80, true);
  bounded(value.subtitle, "subtitle", 120, false);
  validateAction(value.action);
  switch (value.type) {
    case "stats": validateMetrics(value.metrics, 8, false); break;
    case "metrics": validateMetrics(value.metrics, 4, true); break;
    case "progress": {
      if (finite(value.percentage)) {
        if (value.percentage < 0 || value.percentage > 100) throw new Error("percentage must be between 0 and 100");
      } else if (!finite(value.value) || !finite(value.upperLimit) || value.upperLimit <= 0 || value.value < 0 || value.value > value.upperLimit) {
        throw new Error("progress requires percentage or value with a positive upperLimit");
      }
      break;
    }
    case "segmented_progress":
      if (!Number.isInteger(value.numberOfSteps) || value.numberOfSteps < 1 || value.numberOfSteps > 12) {
        throw new Error("numberOfSteps must be between 1 and 12");
      }
      if (!Number.isInteger(value.currentStep) || value.currentStep < 0 || value.currentStep > value.numberOfSteps) {
        throw new Error("currentStep must be between 0 and numberOfSteps");
      }
      bounded(value.stepLabel, "stepLabel", 80, false);
      break;
    case "alert":
      bounded(value.message, "message", 240, true);
      validateAdornment(value.icon, "icon", "symbol", 80);
      validateAdornment(value.badge, "badge", "title", 24);
      break;
    case "timer":
      if (!Number.isInteger(value.durationSeconds) || value.durationSeconds < 1 || value.durationSeconds > 604800) {
        throw new Error("durationSeconds must be between 1 and 604800");
      }
      if (value.countsDown !== undefined && typeof value.countsDown !== "boolean") {
        throw new Error("countsDown must be boolean");
      }
      break;
  }
}

function validateMetrics(value, maximum, numeric) {
  if (!Array.isArray(value) || value.length < 1 || value.length > maximum) {
    throw new Error(`metrics must contain between 1 and ${maximum} items`);
  }
  value.forEach((metric, index) => {
    if (!isRecord(metric)) throw new Error(`metrics[${index}] must be an object`);
    bounded(metric.label, `metrics[${index}].label`, 40, true);
    if (numeric ? !finite(metric.value) : !(finite(metric.value) || nonEmpty(metric.value))) {
      throw new Error(`metrics[${index}].value has an invalid type`);
    }
    bounded(metric.unit, `metrics[${index}].unit`, 16, false);
    validateColor(metric.color, `metrics[${index}].color`);
  });
}

function validateAdornment(value, name, key, maximum) {
  if (value === undefined) return;
  if (!isRecord(value)) throw new Error(`${name} must be an object`);
  bounded(value[key], `${name}.${key}`, maximum, true);
  validateColor(value.color, `${name}.color`);
}

function validateAction(value) {
  if (value === undefined) return;
  if (!isRecord(value) || value.type !== "open_url") throw new Error("action.type must be open_url");
  bounded(value.title, "action.title", 40, true);
  bounded(value.url, "action.url", 2048, true);
  try {
    const url = new URL(value.url);
    if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error();
  } catch {
    throw new Error("action.url must use http or https");
  }
}

function validateColor(value, name) {
  if (value !== undefined && !SURFACE_COLORS.has(value)) {
    throw new Error(`${name} is not a supported color`);
  }
}

function bounded(value, name, maximum, requiredValue) {
  if (value === undefined && !requiredValue) return;
  if (!nonEmpty(value)) throw new Error(`${name} is required`);
  if (value.length > maximum) throw new Error(`${name} must be at most ${maximum} characters`);
}

function finite(value) {
  return typeof value === "number" && Number.isFinite(value);
}

function required(args, key) {
  const value = args[key];
  if (!nonEmpty(value)) throw new Error(`--${key} is required`);
  return value;
}

function nonEmpty(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function validateLogoUrl(value) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || !url.hostname || value.length > 2048) {
      throw new Error("invalid");
    }
  } catch {
    throw new Error("--logo-url must be a public HTTPS URL up to 2048 characters");
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function printResult(value, json) {
  if (json) {
    process.stdout.write(`${JSON.stringify(value)}\n`);
    return;
  }
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function printHelp() {
  process.stdout.write(`Bellwire CLI\n\nUsage:\n  bellwire.mjs <command> [options] [--json]\n\nCommands:\n  bind --code <6 digits> [--name <agent>]\n  list-projects\n  create-project --name <name> [--logo-url <https-url>] [--icon <sf-symbol>] [--category <name>]\n  update-project --project <id> [--logo-url <https-url> | --clear-logo] [--name <name>] [--status active|paused]\n  validate-spec --file <event-spec.json>\n  create-schema --project <id> --file <event-spec.json>\n  create-token --project <id> [--name <name>]\n  validate-surface --file <surface.json>\n  upsert-surface --project <id> --key <stable-key> --file <surface.json>\n  list-surfaces [--project <id>]\n  delete-surface --project <id> --key <stable-key>\n  send-test --project <id> --file <test-event.json>\n  event --event <id>\n  health --project <id>\n\nEnvironment:\n  BELLWIRE_AGENT_TOKEN  Management token (except bind)\n  BELLWIRE_API_URL      Override the hosted API URL\n`);
}
