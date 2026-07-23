// SPDX-License-Identifier: AGPL-3.0-only
import { readFileSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import process from "node:process";

import { describe, expect, it } from "vitest";

const repositoryRoot = resolve(import.meta.dirname, "..");
const templatesRoot = join(repositoryRoot, "examples/templates");
const cli = join(repositoryRoot, "skills/bellwire/scripts/bellwire.mjs");

describe("public integration examples", () => {
  it("ships valid Event Specs with matching synthetic payloads", () => {
    const specFiles = readdirSync(templatesRoot)
      .filter((name) => name.endsWith(".event-spec.json"))
      .sort();
    expect(specFiles).toHaveLength(3);

    for (const specFile of specFiles) {
      const validation = spawnSync(
        process.execPath,
        [cli, "validate-spec", "--file", join(templatesRoot, specFile), "--json"],
        { cwd: repositoryRoot, encoding: "utf8" },
      );
      expect(validation.status, validation.stderr).toBe(0);

      const spec = JSON.parse(readFileSync(join(templatesRoot, specFile), "utf8"));
      const eventFile = specFile.replace(".event-spec.json", ".event.json");
      const event = JSON.parse(readFileSync(join(templatesRoot, eventFile), "utf8"));
      expect(event.type).toBe(spec.eventType);
      expect(Object.keys(event.data).sort()).toEqual(Object.keys(spec.fields).sort());
      expect(Number.isNaN(Date.parse(event.occurredAt))).toBe(false);
    }
  });

  it("keeps executable examples syntactically valid and free of token-shaped values", () => {
    const nodeExample = join(repositoryRoot, "examples/node/send-event.mjs");
    const shellExample = join(repositoryRoot, "examples/shell/send-event.sh");
    expect(spawnSync(process.execPath, ["--check", nodeExample]).status).toBe(0);
    expect(spawnSync("bash", ["-n", shellExample]).status).toBe(0);

    const publicSources = [
      readFileSync(nodeExample, "utf8"),
      readFileSync(shellExample, "utf8"),
      ...readdirSync(templatesRoot).map((name) => readFileSync(join(templatesRoot, name), "utf8")),
    ].join("\n");
    expect(publicSources).not.toMatch(/bw_(?:agent|live|ingest)_[A-Za-z0-9_-]{12,}/u);
  });
});
