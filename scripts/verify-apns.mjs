#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import http2 from "node:http2";

import { importPKCS8, SignJWT } from "jose";

const [privateKeyPath, keyId, teamId, bundleId, environment = "sandbox"] = process.argv.slice(2);
if (!privateKeyPath || !keyId || !teamId || !bundleId) {
  throw new Error(
    "Usage: verify-apns.mjs <private-key.p8> <key-id> <team-id> <bundle-id> [sandbox|production]",
  );
}
if (environment !== "sandbox" && environment !== "production") {
  throw new Error("environment must be sandbox or production");
}

const privateKey = await importPKCS8(await readFile(privateKeyPath, "utf8"), "ES256");
const providerToken = await new SignJWT({})
  .setProtectedHeader({ alg: "ES256", kid: keyId })
  .setIssuer(teamId)
  .setIssuedAt()
  .sign(privateKey);
const origin = environment === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

const result = await sendHttp2(origin, {
  ":method": "POST",
  ":path": `/3/device/${"0".repeat(64)}`,
  authorization: `bearer ${providerToken}`,
  "apns-topic": bundleId,
  "apns-push-type": "alert",
  "apns-priority": "5",
  "content-type": "application/json",
}, JSON.stringify({ aps: { alert: { title: "Bellwire verification", body: "Credential check" } } }));

let responseBody = {};
try {
  responseBody = result.body ? JSON.parse(result.body) : {};
} catch {
  responseBody = {};
}

if (result.status !== 400 || responseBody.reason !== "BadDeviceToken") {
  throw new Error(
    `APNs credential verification failed with ${result.status}: ${responseBody.reason ?? "Unknown response"}`,
  );
}

console.log(JSON.stringify({
  verified: true,
  environment,
  bundleId,
  apnsResponse: responseBody.reason,
}, null, 2));

function sendHttp2(originUrl, headers, body) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(originUrl);
    client.once("error", reject);
    const request = client.request(headers);
    let status = 0;
    let response = "";
    request.setEncoding("utf8");
    request.on("response", (incomingHeaders) => {
      status = Number(incomingHeaders[":status"] ?? 0);
    });
    request.on("data", (chunk) => { response += chunk; });
    request.once("error", reject);
    request.on("end", () => {
      client.close();
      resolve({ status, body: response });
    });
    request.end(body);
  });
}
