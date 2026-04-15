#!/usr/bin/env bash
# ============================================================================
# create-destination.sh
#
# Creates a BTP HTTP destination that connects Joule to a CF-deployed A2A agent.
#
# Prerequisites:
#   - cf CLI v8 logged in and targeting the correct org/space
#   - python3 installed (for JSON parsing — handles PEM keys that break jq)
#   - The A2A agent app already deployed to CF (cf push)
#   - A destination service instance in the subaccount
#
# Usage:
#   ./create-destination.sh \
#     --agent-name po-assistant \
#     --destination-name POAssistant_A2A \
#     --landscape eu10
#
#   Or with all options:
#   ./create-destination.sh \
#     --agent-name po-assistant \
#     --destination-name POAssistant_A2A \
#     --landscape eu10 \
#     --dest-service-instance my-dest-service \
#     --dest-service-key my-dest-key \
#     --auth NoAuthentication
# ============================================================================

set -euo pipefail

# ---------- source .env if present ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  echo "Loading .env from ${PROJECT_ROOT}/.env"
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

# ---------- defaults (can be overridden by .env or CLI args) ----------
AGENT_NAME="${CF_APP_NAME:-}"
DESTINATION_NAME="${DESTINATION_NAME:-}"
LANDSCAPE="${CF_LANDSCAPE:-}"
DEST_SERVICE_INSTANCE="destination-service"
DEST_SERVICE_KEY="destination-service-key"
AUTH_TYPE="NoAuthentication"
AGENT_URL=""  # auto-derived from cf app if empty

# ---------- parse args ----------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --agent-name NAME          CF app name of the deployed A2A agent
  --destination-name NAME    BTP destination name (must match system_alias in capability.sapdas.yaml)
  --landscape LANDSCAPE      CF landscape (e.g. eu10, us10, ap10)

Optional:
  --agent-url URL            Override agent URL (auto-detected from cf app if omitted)
  --dest-service-instance    Destination service instance name (default: destination-service)
  --dest-service-key         Destination service key name (default: destination-service-key)
  --auth TYPE                Authentication type: NoAuthentication (default) or OAuth2ClientCredentials

Examples:
  # Minimal — auto-detects agent URL from cf app
  $(basename "$0") --agent-name po-assistant --destination-name POAssistant_A2A --landscape eu10

  # Explicit URL
  $(basename "$0") --agent-name po-assistant --destination-name POAssistant_A2A --landscape eu10 \\
    --agent-url https://po-assistant.cfapps.eu10.hana.ondemand.com
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent-name)         AGENT_NAME="$2";              shift 2 ;;
    --destination-name)   DESTINATION_NAME="$2";        shift 2 ;;
    --landscape)          LANDSCAPE="$2";               shift 2 ;;
    --agent-url)          AGENT_URL="$2";               shift 2 ;;
    --dest-service-instance) DEST_SERVICE_INSTANCE="$2"; shift 2 ;;
    --dest-service-key)   DEST_SERVICE_KEY="$2";        shift 2 ;;
    --auth)               AUTH_TYPE="$2";               shift 2 ;;
    -h|--help)            usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------- validate required args ----------
if [[ -z "$AGENT_NAME" || -z "$DESTINATION_NAME" || -z "$LANDSCAPE" ]]; then
  echo "Error: --agent-name, --destination-name, and --landscape are required."
  usage
fi

# ---------- check dependencies ----------
for cmd in cf curl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

echo "============================================"
echo " BTP Destination Creator for Joule A2A Agent"
echo "============================================"
echo ""

# ==========================================================================
# Step 1: Detect agent URL from CF app (if not provided)
# ==========================================================================
if [[ -z "$AGENT_URL" ]]; then
  echo "[1/5] Detecting agent URL from cf app '${AGENT_NAME}'..."
  APP_INFO=$(cf app "$AGENT_NAME" --guid 2>/dev/null) || {
    echo "Error: CF app '${AGENT_NAME}' not found. Deploy it first with 'cf push'."
    exit 1
  }

  # Get the route from the app
  ROUTE=$(cf curl "/v3/apps/${APP_INFO}/routes" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('resources',[]); print(r[0]['url'] if r else '')")

  if [[ -z "$ROUTE" ]]; then
    # Fallback: construct from app name + landscape
    AGENT_URL="https://${AGENT_NAME}.cfapps.${LANDSCAPE}.hana.ondemand.com"
    echo "  Could not detect route via API. Using default: ${AGENT_URL}"
  else
    AGENT_URL="https://${ROUTE}"
    echo "  Detected: ${AGENT_URL}"
  fi
else
  echo "[1/5] Using provided agent URL: ${AGENT_URL}"
fi

# Quick health check — verify agent card is reachable
echo "  Checking agent card at ${AGENT_URL}/.well-known/agent.json ..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${AGENT_URL}/.well-known/agent.json" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "200" ]]; then
  echo "  Agent card reachable (HTTP 200)"
elif [[ "$HTTP_STATUS" == "000" ]]; then
  echo "  Warning: Could not reach agent URL. It may not be deployed yet or may be behind auth."
  echo "  Continuing anyway — the destination will be created."
else
  echo "  Warning: Agent card returned HTTP ${HTTP_STATUS}. Continuing anyway."
fi
echo ""

# ==========================================================================
# Step 2: Ensure destination service instance exists
# ==========================================================================
echo "[2/5] Checking destination service instance '${DEST_SERVICE_INSTANCE}'..."

if cf service "$DEST_SERVICE_INSTANCE" &>/dev/null; then
  echo "  Instance already exists."
else
  echo "  Creating destination service instance..."
  cf create-service destination lite "$DEST_SERVICE_INSTANCE"
  echo "  Waiting for service to be ready..."
  sleep 5

  # Poll until ready (max 60 seconds)
  for i in $(seq 1 12); do
    STATUS=$(cf service "$DEST_SERVICE_INSTANCE" | grep "status:" | awk '{print $NF}' 2>/dev/null || echo "unknown")
    if [[ "$STATUS" == *"succeeded"* || "$STATUS" == *"create"* ]]; then
      break
    fi
    sleep 5
  done
  echo "  Destination service instance created."
fi
echo ""

# ==========================================================================
# Step 3: Create or reuse service key
# ==========================================================================
echo "[3/5] Getting destination service credentials..."

# Check if key exists
if cf service-key "$DEST_SERVICE_INSTANCE" "$DEST_SERVICE_KEY" &>/dev/null 2>&1; then
  echo "  Service key '${DEST_SERVICE_KEY}' already exists."
else
  echo "  Creating service key '${DEST_SERVICE_KEY}'..."
  cf create-service-key "$DEST_SERVICE_INSTANCE" "$DEST_SERVICE_KEY"
fi

# Extract credentials from service key
# Note: jq cannot parse cf service-key output when it contains PEM certificates
# with control characters, so we use python3 for reliable JSON parsing.
# We also avoid eval (which breaks when clientsecret contains newlines or special chars)
# by writing to a temp file with proper quoting.
CREDS_JSON=$(cf service-key "$DEST_SERVICE_INSTANCE" "$DEST_SERVICE_KEY" 2>/dev/null \
  | tail -n +2)  # skip the first line (header)

CREDS_FILE=$(mktemp)
trap "rm -f '$CREDS_FILE'" EXIT

python3 -c "
import json, sys, shlex
try:
    data = json.loads(sys.stdin.read())
    creds = data.get('credentials', data)
    uri = creds.get('uri', '')
    uaa = creds.get('uaa', {})
    # Use shlex.quote to safely handle any special characters in values
    print(f'DEST_API_URI={shlex.quote(uri)}')
    print(f'DEST_CLIENT_ID={shlex.quote(uaa.get(\"clientid\", \"\"))}')
    print(f'DEST_CLIENT_SECRET={shlex.quote(uaa.get(\"clientsecret\", \"\"))}')
    print(f'DEST_TOKEN_URL={shlex.quote(uaa.get(\"url\", \"\"))}')
except Exception as e:
    print(f'echo \"Error parsing credentials: {e}\"', file=sys.stderr)
    sys.exit(1)
" <<< "$CREDS_JSON" > "$CREDS_FILE"

source "$CREDS_FILE"
rm -f "$CREDS_FILE"

if [[ -z "$DEST_API_URI" || -z "$DEST_CLIENT_ID" || -z "$DEST_CLIENT_SECRET" || -z "$DEST_TOKEN_URL" ]]; then
  echo "Error: Could not extract destination service credentials."
  echo "Raw credentials output:"
  echo "$CREDS_JSON"
  exit 1
fi

echo "  Destination API: ${DEST_API_URI}"
echo "  Token URL: ${DEST_TOKEN_URL}"
echo ""

# ==========================================================================
# Step 4: Get OAuth token for Destination Service API
# ==========================================================================
echo "[4/5] Authenticating with Destination Service..."

TOKEN_RESPONSE=$(curl -s -X POST "${DEST_TOKEN_URL}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${DEST_CLIENT_ID}" \
  -d "client_secret=${DEST_CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Error: Could not obtain OAuth token."
  echo "Response: ${TOKEN_RESPONSE}"
  exit 1
fi

echo "  OAuth token obtained."
echo ""

# ==========================================================================
# Step 5: Create the destination via REST API
# ==========================================================================
echo "[5/5] Creating destination '${DESTINATION_NAME}'..."

# Build the destination JSON payload
DEST_PAYLOAD=$(cat <<ENDJSON
{
  "Name": "${DESTINATION_NAME}",
  "Type": "HTTP",
  "URL": "${AGENT_URL}",
  "ProxyType": "Internet",
  "Authentication": "${AUTH_TYPE}",
  "HTML5.DynamicDestination": "true",
  "WebIDEEnabled": "true",
  "Description": "A2A destination for Joule agent: ${AGENT_NAME}"
}
ENDJSON
)

# Check if destination already exists
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "${DEST_API_URI}/destination-configuration/v1/subaccountDestinations/${DESTINATION_NAME}")

if [[ "$EXISTING" == "200" ]]; then
  echo "  Destination '${DESTINATION_NAME}' already exists. Updating..."
  HTTP_METHOD="PUT"
else
  echo "  Creating new destination..."
  HTTP_METHOD="POST"
fi

# Create or update the destination
if [[ "$HTTP_METHOD" == "PUT" ]]; then
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X PUT \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$DEST_PAYLOAD" \
    "${DEST_API_URI}/destination-configuration/v1/subaccountDestinations/${DESTINATION_NAME}")
else
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$DEST_PAYLOAD" \
    "${DEST_API_URI}/destination-configuration/v1/subaccountDestinations")
fi

RESPONSE_BODY=$(echo "$RESPONSE" | head -n -1)
RESPONSE_CODE=$(echo "$RESPONSE" | tail -n 1)

if [[ "$RESPONSE_CODE" == "201" || "$RESPONSE_CODE" == "200" || "$RESPONSE_CODE" == "204" ]]; then
  echo ""
  echo "============================================"
  echo " Destination created successfully!"
  echo "============================================"
  echo ""
  echo "  Name:           ${DESTINATION_NAME}"
  echo "  URL:            ${AGENT_URL}"
  echo "  Type:           HTTP"
  echo "  Authentication: ${AUTH_TYPE}"
  echo "  ProxyType:      Internet"
  echo "  Properties:"
  echo "    HTML5.DynamicDestination = true"
  echo "    WebIDEEnabled            = true"
  echo ""
  echo "Next steps:"
  echo "  1. Ensure your capability.sapdas.yaml has: system_alias: \"${DESTINATION_NAME}\""
  echo "  2. Deploy to Joule:"
  echo "     cd joule-capability"
  echo "     joule deploy ./da.sapdas.yaml --compile -n \"$(echo "${AGENT_NAME}" | tr '-' '_')\""
  echo ""
else
  echo ""
  echo "Error: Destination API returned HTTP ${RESPONSE_CODE}"
  echo "Response: ${RESPONSE_BODY}"
  echo ""
  echo "Common causes:"
  echo "  - 409 Conflict: destination already exists (try updating manually in BTP cockpit)"
  echo "  - 401/403: insufficient permissions — check your subaccount roles"
  echo "  - 400 Bad Request: invalid payload format"
  exit 1
fi
