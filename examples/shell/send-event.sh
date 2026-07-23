#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

: "${BELLWIRE_PROJECT_ID:?BELLWIRE_PROJECT_ID is required}"
: "${BELLWIRE_INGEST_TOKEN:?BELLWIRE_INGEST_TOKEN is required}"
: "${BELLWIRE_EVENT_FILE:?BELLWIRE_EVENT_FILE is required}"
: "${BELLWIRE_IDEMPOTENCY_KEY:?BELLWIRE_IDEMPOTENCY_KEY is required}"

bellwire_api_url="${BELLWIRE_API_URL:-https://api.bellwire.app}"

curl --fail-with-body --silent --show-error \
  --max-time 5 \
  --request POST \
  --header "Authorization: Bearer ${BELLWIRE_INGEST_TOKEN}" \
  --header "Content-Type: application/json" \
  --header "Idempotency-Key: ${BELLWIRE_IDEMPOTENCY_KEY}" \
  --data-binary "@${BELLWIRE_EVENT_FILE}" \
  "${bellwire_api_url%/}/v1/events/${BELLWIRE_PROJECT_ID}"
