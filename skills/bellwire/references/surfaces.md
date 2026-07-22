# Bellwire live Surfaces

Live Surfaces are mutable, agent-defined cards. Use a stable lowercase key so
later calls update the same card instead of creating duplicates.

For production application code, call the same `PUT` endpoint with the
project-scoped `BELLWIRE_INGEST_TOKEN`. Reserve `BELLWIRE_AGENT_TOKEN` for the
management CLI and configuration work.

```bash
node <skill-dir>/scripts/bellwire.mjs upsert-surface \
  --project <project-id> \
  --key sales-today \
  --file surface.json
```

Every Surface requires `type` and `title`; `subtitle` and an `open_url` action
are optional. Bellwire renders only the native types below and never executes
code from a Surface payload.

## `stats`

Use for already-computed business values. Supports 1-8 metrics. Values may be
strings or numbers.

```json
{
  "type": "stats",
  "title": "Sales",
  "subtitle": "Today",
  "metrics": [
    { "label": "Revenue", "value": "¥2,430", "color": "green" },
    { "label": "Orders", "value": 37, "color": "blue" }
  ]
}
```

## `metrics`

Use for 1-4 numeric operational measurements. Each metric may include `unit`.

```json
{
  "type": "metrics",
  "title": "API health",
  "metrics": [
    { "label": "CPU", "value": 18, "unit": "%", "color": "cyan" },
    { "label": "Memory", "value": 42, "unit": "%", "color": "purple" }
  ]
}
```

## `progress`

Send either `percentage` from 0-100, or `value` with a positive `upperLimit`.

```json
{ "type": "progress", "title": "Search reindex", "percentage": 68 }
```

## `segmented_progress`

Use 1-12 steps and a `currentStep` from zero through the step count.

```json
{
  "type": "segmented_progress",
  "title": "Production deploy",
  "numberOfSteps": 5,
  "currentStep": 3,
  "stepLabel": "Running migrations"
}
```

## `alert`

Use for an important current state. `icon.symbol` accepts an SF Symbol name.

```json
{
  "type": "alert",
  "title": "Approval needed",
  "message": "Send the follow-up to Brightlane?",
  "icon": { "symbol": "sparkles", "color": "yellow" },
  "badge": { "title": "Agent", "color": "green" }
}
```

## `timer`

Use `durationSeconds` from 1 second through 7 days. Set `countsDown` to false
for elapsed runtime.

```json
{ "type": "timer", "title": "Benchmark", "durationSeconds": 300, "countsDown": true }
```

Supported colors are `lime`, `green`, `cyan`, `blue`, `purple`, `magenta`,
`red`, `orange`, `yellow`, and `gray`.
