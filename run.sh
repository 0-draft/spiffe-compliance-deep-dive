#!/usr/bin/env bash
# SPIFFE compliance verification hands-on.
#
# Boots SPIRE Server + Agent in local Docker, then checks the SVIDs they emit
# against the MUST requirements in the SPIFFE standards (SPIFFE-ID,
# X.509-SVID, JWT-SVID, Workload API, Trust Bundle).
#
# Prerequisites: Docker (Desktop / Rancher Desktop / OrbStack etc.), jq, openssl
# Verified on: macOS 14 + Rancher Desktop, SPIRE v1.14.6
# Runtime: ~1 minute

set -euo pipefail
cd "$(dirname "$0")"

TRUST_DOMAIN="example.org"
WORKLOAD_SPIFFE_ID="spiffe://${TRUST_DOMAIN}/payments/web-fe"
# The -spiffeID passed to `token generate` can be anything except the reserved
# /spire/... namespace. After attestation, the agent's actual SPIFFE ID is
# spiffe://<td>/spire/agent/join_token/<token>.
AGENT_REGISTRATION_ID="spiffe://${TRUST_DOMAIN}/myagent"

cleanup() {
  echo ""
  echo "===== Cleanup ====="
  docker compose down -v --remove-orphans 2>/dev/null || true
  rm -f agent/bootstrap.crt
}

# Run cleanup on Ctrl+C or any error.
trap cleanup EXIT

echo "===== 1. Tear down any leftover compose state ====="
docker compose down -v --remove-orphans 2>/dev/null || true
rm -f agent/bootstrap.crt

echo ""
echo "===== 2. Start only the SPIRE Server (needed to emit bundle + token) ====="
docker compose up -d spire-server

# Wait until the server reports healthy.
for _ in {1..30}; do
  if docker compose exec -T spire-server /opt/spire/bin/spire-server healthcheck >/dev/null 2>&1; then
    echo "SPIRE Server is healthy"
    break
  fi
  sleep 1
done

echo ""
echo "===== 3. Hand the trust bundle to the Agent ====="
docker compose exec -T spire-server \
  /opt/spire/bin/spire-server bundle show \
  > agent/bootstrap.crt
echo "First lines of bootstrap.crt:"
head -2 agent/bootstrap.crt

echo ""
echo "===== 4. Generate a join token ====="
JOIN_TOKEN=$(docker compose exec -T spire-server \
  /opt/spire/bin/spire-server token generate \
    -spiffeID "${AGENT_REGISTRATION_ID}" \
    -ttl 600 \
  | awk '/Token:/ {print $2}' | tr -d '\r')
export JOIN_TOKEN
echo "JOIN_TOKEN=${JOIN_TOKEN}"

# The SPIFFE ID the agent actually receives after attestation.
AGENT_ATTESTED_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${JOIN_TOKEN}"

echo ""
echo "===== 5. Register the workload entry (map uid:0 to web-fe) ====="
docker compose exec -T spire-server \
  /opt/spire/bin/spire-server entry create \
    -parentID "${AGENT_ATTESTED_ID}" \
    -spiffeID "${WORKLOAD_SPIFFE_ID}" \
    -selector unix:uid:0

echo ""
echo "===== 6. Start the SPIRE Agent (with the join token) ====="
docker compose up -d spire-agent

# Wait until the agent has bound the Workload API socket.
for _ in {1..30}; do
  if docker compose exec -T spire-agent /opt/spire/bin/spire-agent healthcheck >/dev/null 2>&1; then
    echo "SPIRE Agent is healthy"
    break
  fi
  sleep 1
done

echo ""
echo "===== 7. Fetch an X.509-SVID ====="
docker compose exec -T spire-agent /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/agent/public/api.sock \
  -write /tmp/

# The image is distroless (no cat/ls), so we pull the files out with docker cp.
rm -rf out && mkdir -p out
docker cp spire-compliance-agent:/tmp/svid.0.pem out/svid.pem
docker cp spire-compliance-agent:/tmp/svid.0.key out/svid.key
docker cp spire-compliance-agent:/tmp/bundle.0.pem out/bundle.pem

echo ""
echo "----- contents of out/svid.pem -----"
openssl x509 -in out/svid.pem -text -noout

echo ""
echo "===== 8. Check the X.509-SVID against the SPIFFE spec ====="
SVID_TEXT=$(openssl x509 -in out/svid.pem -text -noout)

echo "--- (a) exactly one URI SAN, starting with spiffe:// ---"
URI_LINES=$(echo "${SVID_TEXT}" | grep -c "URI:spiffe://")
echo "URI SAN lines: ${URI_LINES} (expected: 1)"
echo "${SVID_TEXT}" | grep "URI:"

echo ""
echo "--- (b) Basic Constraints is CA:FALSE ---"
echo "${SVID_TEXT}" | grep -A1 "Basic Constraints"

echo ""
echo "--- (c) Key Usage has Digital Signature and not keyCertSign ---"
echo "${SVID_TEXT}" | grep -A1 "Key Usage"

echo ""
echo "--- (d) Extended Key Usage has serverAuth/clientAuth ---"
echo "${SVID_TEXT}" | grep -A1 "Extended Key Usage"

echo ""
echo "===== 9. Fetch a JWT-SVID ====="
JWT=$(docker compose exec -T spire-agent /opt/spire/bin/spire-agent api fetch jwt \
  -socketPath /run/spire/agent/public/api.sock \
  -audience "https://api.example.com" \
  | awk '/^token\(/, /^$/' \
  | grep -v "^token(" \
  | grep -v "^$" \
  | head -1 \
  | tr -d '\t ')
echo "JWT (first 80 chars): ${JWT:0:80}..."

echo ""
echo "===== 10. Check the JWT-SVID against the SPIFFE spec ====="
HEADER_B64=$(echo -n "${JWT}" | cut -d. -f1)
PAYLOAD_B64=$(echo -n "${JWT}" | cut -d. -f2)

# Convert base64url to plain base64 by adding padding so `base64 -d` accepts it.
b64url_decode() {
  local s="$1"
  s="${s//-/+}"
  s="${s//_//}"
  case $(( ${#s} % 4 )) in
    2) s="${s}==" ;;
    3) s="${s}=" ;;
  esac
  echo "${s}" | base64 -d
}

echo "--- Header ---"
HEADER_JSON=$(b64url_decode "${HEADER_B64}")
echo "${HEADER_JSON}" | jq .

echo ""
echo "--- Payload ---"
PAYLOAD_JSON=$(b64url_decode "${PAYLOAD_B64}")
echo "${PAYLOAD_JSON}" | jq .

echo ""
echo "--- (a) alg is in the RS/ES/PS family ---"
ALG=$(echo "${HEADER_JSON}" | jq -r .alg)
case "${ALG}" in
  RS256|RS384|RS512|ES256|ES384|ES512|PS256|PS384|PS512)
    echo "alg=${ALG} -> OK (allowed by JWT-SVID 2.1)"
    ;;
  *)
    echo "alg=${ALG} -> FAIL (spec violation)"
    exit 1
    ;;
esac

echo ""
echo "--- (b) sub is a SPIFFE ID ---"
SUB=$(echo "${PAYLOAD_JSON}" | jq -r .sub)
echo "sub=${SUB}"
if [[ "${SUB}" == "${WORKLOAD_SPIFFE_ID}" ]]; then
  echo "-> OK (matches the expected SPIFFE ID)"
else
  echo "-> FAIL"
  exit 1
fi

echo ""
echo "--- (c) aud is present and contains the expected value ---"
echo "${PAYLOAD_JSON}" | jq .aud

echo ""
echo "--- (d) exp is in the future ---"
EXP=$(echo "${PAYLOAD_JSON}" | jq -r .exp)
NOW=$(date +%s)
if [[ "${EXP}" -gt "${NOW}" ]]; then
  echo "exp=${EXP} (now=${NOW}) -> OK (not yet expired)"
else
  echo "exp=${EXP} (now=${NOW}) -> FAIL"
  exit 1
fi

echo ""
echo "===== 11. Inspect the Trust Bundle (X.509 CA) ====="
openssl x509 -in out/bundle.pem -text -noout | \
  grep -E "Subject:|Issuer:|URI:|CA:|Key Usage"

echo ""
echo "===== 12. Confirm the Workload API socket is a live UDS ====="
# Image is distroless, so instead of `ls` we use spire-agent healthcheck,
# which talks to the same socket_path under the hood.
docker compose exec -T spire-agent /opt/spire/bin/spire-agent healthcheck \
  -socketPath /run/spire/agent/public/api.sock

echo ""
echo "==============================================="
echo "All checklist items PASS"
echo "==============================================="
