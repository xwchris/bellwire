import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

describe("iOS Inbox preview", () => {
  it("excludes server-declared sensitive fields and decodes legacy responses", () => {
    const temporaryDirectory = mkdtempSync(join(tmpdir(), "bellwire-ios-preview-"));
    const executable = join(temporaryDirectory, "InboxPreviewCheck");
    try {
      execFileSync("xcrun", [
        "swiftc",
        "ios/Bellwire/Bellwire/Models.swift",
        "test/InboxPreviewCheck.swift",
        "-o",
        executable,
      ], { stdio: "pipe" });
      expect(() => execFileSync(executable, { stdio: "pipe" })).not.toThrow();
    } finally {
      rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  });
});
