<!-- SPDX-License-Identifier: Apache-2.0 -->

# Changelog

All notable changes to Bellwire are documented here. The project follows
[Semantic Versioning](https://semver.org/) for public repository releases.

## [Unreleased]

## [0.1.0] - 2026-07-23

### Added

- Cloudflare Worker API for projects, devices, typed events, notification
  Surfaces, live Surfaces, delivery state, and scoped Agent/Ingest tokens.
- Supabase-backed authentication, durable storage, migrations, and account
  deletion with Sign in with Apple token revocation.
- Native iOS 17 SwiftUI app with Sign in with Apple, APNs registration, inbox,
  project cards, event history, deep links, localization, and appearance
  controls.
- Bellwire Agent Skill and dependency-free CLI for connecting repositories.
- Hosted quick start, complete self-hosting guide, bootstrap/doctor/APNs
  preflight tools, integration examples, and architecture decisions.
- CI, CodeQL, Dependabot, issue templates, contribution guidance, security
  reporting, and automated license-boundary checks.

### Licensing

- Worker, Supabase, and operational tooling under `AGPL-3.0-only`.
- Native iOS app under `MPL-2.0`.
- Skill, CLI, protocol references, examples, and public documentation under
  `Apache-2.0`.
- Bellwire name, app icon, and official service identifiers reserved under the
  trademark policy.

[Unreleased]: https://github.com/xwchris/bellwire/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/xwchris/bellwire/releases/tag/v0.1.0
