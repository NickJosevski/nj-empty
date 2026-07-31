#!/usr/bin/env bash
#
# Buildkite -> Octopus Deploy via OpenID Connect, with no Octopus API key.
#
# This is the hand-rolled equivalent of what OctopusDeploy/login@v2 does for
# GitHub Actions (see src/login.ts in OctopusDeploy/login). Buildkite has no
# such plugin, so the job has to do it itself:
#   1. ask the agent for an OIDC ID token, audience = Octopus service account id
#   2. discover Octopus's token_endpoint via OpenID discovery
#   3. exchange the ID token for a short-lived Octopus access token (RFC 8693)
#   4. use it as a normal Bearer token
#
set -euo pipefail

OCTOPUS_URL="https://md.octopus.app"
SERVICE_ACCOUNT_ID="d5de4670-4678-4c08-9479-09555cd6ccbb"
SPACE_ID="Spaces-162"
PROJECT_ID="Projects-181"

# Decode a JWT payload for display. Never echoes the token itself.
decode_jwt_payload() {
  python3 -c '
import base64, json, sys
payload = sys.argv[1].split(".")[1]
payload += "=" * (-len(payload) % 4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(payload)), indent=2, sort_keys=True))
' "$1"
}

echo "--- :key: 1. Ask Buildkite for an OIDC ID token"
ID_TOKEN="$(buildkite-agent oidc request-token --audience "$SERVICE_ACCOUNT_ID")"
echo "id token acquired, length ${#ID_TOKEN}"

echo "--- :mag: 2. What did Buildkite actually put in it?"
decode_jwt_payload "$ID_TOKEN"

echo "--- :satellite: 3. Discover the Octopus token endpoint"
TOKEN_ENDPOINT="$(curl -sSf "$OCTOPUS_URL/.well-known/openid-configuration" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_endpoint"])')"
echo "token_endpoint=$TOKEN_ENDPOINT"

echo "--- :arrows_counterclockwise: 4. Exchange it (RFC 8693 token exchange)"
EXCHANGE_BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
    "audience": sys.argv[1],
    "subject_token": sys.argv[2],
    "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
}))
' "$SERVICE_ACCOUNT_ID" "$ID_TOKEN")"

HTTP_CODE="$(curl -sS -o /tmp/exchange.json -w '%{http_code}' \
  -X POST "$TOKEN_ENDPOINT" \
  -H 'Content-Type: application/json' \
  -d "$EXCHANGE_BODY")"
echo "exchange HTTP $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ]; then
  echo "^^^ exchange failed. Response body:"
  cat /tmp/exchange.json
  echo
  echo "Compare the 'sub' printed in step 2 against the Subject configured on the"
  echo "Octopus service account's OIDC identity - they must match exactly."
  exit 1
fi

ACCESS_TOKEN="$(python3 -c 'import json;print(json.load(open("/tmp/exchange.json"))["access_token"])')"
echo "access token acquired, length ${#ACCESS_TOKEN}"
python3 -c '
import json
d = json.load(open("/tmp/exchange.json"))
print("token_type=%s  issued_token_type=%s  expires_in=%s" % (
    d.get("token_type"), d.get("issued_token_type"), d.get("expires_in")))
'

echo "--- :closed_lock_with_key: 5. Claims Octopus put in ITS access token"
decode_jwt_payload "$ACCESS_TOKEN"

echo "--- :octopus: 6. Which Octopus principal did this resolve to?"
curl -sSf -H "Authorization: Bearer $ACCESS_TOKEN" "$OCTOPUS_URL/api/users/me" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({k: d[k] for k in ("Id", "Username", "DisplayName", "IsService")}, indent=2))
'

echo "--- :rocket: 7. A real operation: create a release"
RELEASE_BODY="$(python3 -c '
import json, sys
print(json.dumps({"ProjectId": sys.argv[1], "Version": "2.0.%s" % sys.argv[2]}))
' "$PROJECT_ID" "$BUILDKITE_BUILD_NUMBER")"

HTTP_CODE="$(curl -sS -o /tmp/release.json -w '%{http_code}' \
  -X POST "$OCTOPUS_URL/api/$SPACE_ID/releases" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$RELEASE_BODY")"
echo "create release HTTP $HTTP_CODE"
python3 -c '
import json
d = json.load(open("/tmp/release.json"))
print(json.dumps({k: d.get(k) for k in
    ("Id", "Version", "ProjectId", "Assembled", "ErrorMessage", "Errors")}, indent=2))
'
[ "$HTTP_CODE" = "201" ] || exit 1

echo "--- :white_check_mark: Done - no Octopus API key existed anywhere in this build"
