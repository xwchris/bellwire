// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

describe("iOS Inbox preview", () => {
  it(
    "excludes server-declared sensitive fields and decodes legacy responses",
    () => {
      const temporaryDirectory = mkdtempSync(
        join(tmpdir(), "bellwire-ios-preview-"),
      );
      const executable = join(temporaryDirectory, "InboxPreviewCheck");
      try {
        execFileSync(
          "xcrun",
          [
            "swiftc",
            "ios/Bellwire/Bellwire/Models.swift",
            "test/InboxPreviewCheck.swift",
            "-o",
            executable,
          ],
          { stdio: "pipe" },
        );
        expect(() => execFileSync(executable, { stdio: "pipe" })).not.toThrow();
      } finally {
        rmSync(temporaryDirectory, { recursive: true, force: true });
      }
    },
    30_000,
  );

  it(
    "formats dates using the in-app language instead of the system locale",
    () => {
      const temporaryDirectory = mkdtempSync(
        join(tmpdir(), "bellwire-ios-locale-"),
      );
      const executable = join(temporaryDirectory, "LocalizationCheck");
      try {
        execFileSync(
          "xcrun",
          [
            "swiftc",
            "ios/Bellwire/Bellwire/Localization.swift",
            "test/LocalizationCheck.swift",
            "-o",
            executable,
          ],
          { stdio: "pipe" },
        );
        expect(() => execFileSync(executable, { stdio: "pipe" })).not.toThrow();
      } finally {
        rmSync(temporaryDirectory, { recursive: true, force: true });
      }
    },
    30_000,
  );

  it("refreshes current data from lifecycle and notification signals", () => {
    const app = readFileSync("ios/Bellwire/Bellwire/BellwireApp.swift", "utf8");
    const model = readFileSync("ios/Bellwire/Bellwire/AppModel.swift", "utf8");
    const push = readFileSync("ios/Bellwire/Bellwire/PushDelegate.swift", "utf8");

    expect(app).toContain(".onChange(of: scenePhase)");
    expect(model).toContain("func handleBecameActive() async");
    expect(model).toContain("private var dashboardLoadTask: Task<Void, Never>?");
    expect(model).toContain("private var sessionRefreshTask: Task<AuthSession, Error>?");
    expect(push.match(/handleRemoteNotification/gu)).toHaveLength(2);
  });

  it("keeps the project fallback visible until a remote logo succeeds", () => {
    const components = readFileSync("ios/Bellwire/Bellwire/Components.swift", "utf8");
    const successBranch = components.indexOf("if case .success(let image) = phase");
    const logoBackground = components.indexOf(".background(BellwireTheme.surface)", successBranch);
    const asyncImageEnd = components.indexOf(".frame(width: size, height: size)", successBranch);

    expect(successBranch).toBeGreaterThan(-1);
    expect(logoBackground).toBeGreaterThan(successBranch);
    expect(logoBackground).toBeLessThan(asyncImageEnd);
  });

  it("presents the paywall immediately while StoreKit loads in a large sheet", () => {
    const paywall = readFileSync("ios/Bellwire/Bellwire/PaywallView.swift", "utf8");
    const purchases = readFileSync(
      "ios/Bellwire/Bellwire/PurchaseManager.swift",
      "utf8",
    );
    const chinese = readFileSync(
      "ios/Bellwire/Bellwire/zh-Hans.lproj/Localizable.strings",
      "utf8",
    );
    const settings = readFileSync("ios/Bellwire/Bellwire/SettingsView.swift", "utf8");
    const details = readFileSync("ios/Bellwire/Bellwire/DetailViews.swift", "utf8");

    expect(paywall.indexOf("appeared = true")).toBeLessThan(
      paywall.indexOf("await purchaseManager.prepare()"),
    );
    expect(settings).toContain(".sheet(isPresented: $showsPaywall)");
    expect(details).toContain(".sheet(isPresented: $showsPaywall)");
    expect(settings).toContain(".presentationCornerRadius(BellwireRadius.hero)");
    expect(details).toContain(".presentationCornerRadius(BellwireRadius.hero)");
    expect(paywall).toContain("@Environment(\\.locale) private var locale");
    expect(paywall).toContain(
      'String(localized: "Continue with yearly", locale: locale)',
    );
    expect(paywall).toContain("Text(LocalizedStringKey(errorMessage))");
    expect(purchases).toContain("func title(locale: Locale) -> String");
    expect(purchases).not.toContain("errorMessage = String(localized:");
    expect(chinese).toContain(
      '"Bellwire could not refresh your plan status." = "Bellwire 暂时无法刷新你的套餐状态。";',
    );
  });
});
