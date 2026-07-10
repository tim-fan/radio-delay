#!/bin/bash
# Deploy the analytics worker with plain curl (no wrangler/node needed).
# Needs in .env (or environment):
#   CLOUDFLARE_API_TOKEN  scopes: Workers Scripts:Edit, Account Analytics:Read,
#                         Workers Routes:Edit + Zone:Read on the zone
#   R2_ACCOUNT_ID         (already present for the uploader)
set -euo pipefail

DOMAIN="${DOMAIN:-radio.tim-fan.xyz}"
ZONE_NAME="${ZONE_NAME:-tim-fan.xyz}"
SCRIPT_NAME="${SCRIPT_NAME:-radio-analytics}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../.env}"
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN must be set (see header)}"
: "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID must be set}"

api() {  # api <method> <path> [curl args...]
    local method="$1" path="$2"; shift 2
    curl -sf -X "$method" "https://api.cloudflare.com/client/v4$path" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$@"
}

echo "==> uploading worker script '$SCRIPT_NAME'"
api PUT "/accounts/$R2_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME" \
    -F "metadata={
          \"main_module\": \"worker.js\",
          \"compatibility_date\": \"2026-01-01\",
          \"bindings\": [
            {\"type\": \"analytics_engine\", \"name\": \"LISTENS\", \"dataset\": \"radio_listens\"},
            {\"type\": \"plain_text\", \"name\": \"ACCOUNT_ID\", \"text\": \"$R2_ACCOUNT_ID\"}
          ]
        };type=application/json" \
    -F "worker.js=@$SCRIPT_DIR/worker.js;type=application/javascript+module" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print("    ok" if r["success"] else r["errors"])'

echo "==> setting ANALYTICS_TOKEN secret"
api PUT "/accounts/$R2_ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/secrets" \
    -H 'Content-Type: application/json' \
    --data "{\"name\": \"ANALYTICS_TOKEN\", \"text\": \"${ANALYTICS_API_TOKEN:-$CLOUDFLARE_API_TOKEN}\", \"type\": \"secret_text\"}" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print("    ok" if r["success"] else r["errors"])'

echo "==> ensuring route $DOMAIN/api/*"
ZONE_ID=$(api GET "/zones?name=$ZONE_NAME" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
EXISTING=$(api GET "/zones/$ZONE_ID/workers/routes" | python3 -c "
import json, sys
for r in json.load(sys.stdin)['result']:
    if r['pattern'] == '$DOMAIN/api/*': print(r['id'])")
if [[ -z "$EXISTING" ]]; then
    api POST "/zones/$ZONE_ID/workers/routes" -H 'Content-Type: application/json' \
        --data "{\"pattern\": \"$DOMAIN/api/*\", \"script\": \"$SCRIPT_NAME\"}" >/dev/null
    echo "    route created"
else
    echo "    route already present"
fi

echo "==> smoke test"
curl -sf "https://$DOMAIN/api/stats" | head -c 300; echo
echo "done."
