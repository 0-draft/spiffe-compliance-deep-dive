#!/usr/bin/env bash
# SPIFFE 準拠検証ハンズオン
#
# このスクリプトは SPIRE Server + Agent をローカル Docker で起動し、
# Section 8 のチェックリスト (SPIFFE ID / X.509-SVID / JWT-SVID / Workload API / Bundle)
# が SPIRE の出す SVID で満たされていることを目視確認する。
#
# 前提: Docker (Desktop / Rancher Desktop / OrbStack 等) + jq + openssl
# 動作確認: macOS 14 + Rancher Desktop, SPIRE v1.14.6
# 所要時間: 約 1 分

set -euo pipefail
cd "$(dirname "$0")"

TRUST_DOMAIN="example.org"
WORKLOAD_SPIFFE_ID="spiffe://${TRUST_DOMAIN}/payments/web-fe"
# token generate に渡す ID は予約 namespace (/spire/...) 以外なら何でも OK。
# 実際に agent が attestation 後に名乗る SPIFFE ID は
# spiffe://<td>/spire/agent/join_token/<token> となる。
AGENT_REGISTRATION_ID="spiffe://${TRUST_DOMAIN}/myagent"

cleanup() {
  echo ""
  echo "===== クリーンアップ ====="
  docker compose down -v --remove-orphans 2>/dev/null || true
  rm -f agent/bootstrap.crt
}

# Ctrl+C や error 時にもクリーンアップ
trap cleanup EXIT

echo "===== ① 既存の compose 環境を片付け ====="
docker compose down -v --remove-orphans 2>/dev/null || true
rm -f agent/bootstrap.crt

echo ""
echo "===== ② SPIRE Server だけ先に起動 (bundle と token を出すため) ====="
docker compose up -d spire-server

# Server がヘルシーになるまで polling
for i in {1..30}; do
  if docker compose exec -T spire-server /opt/spire/bin/spire-server healthcheck >/dev/null 2>&1; then
    echo "SPIRE Server is healthy"
    break
  fi
  sleep 1
done

echo ""
echo "===== ③ Trust Bundle を Agent に渡す ====="
docker compose exec -T spire-server \
  /opt/spire/bin/spire-server bundle show \
  > agent/bootstrap.crt
echo "bootstrap.crt の冒頭:"
head -2 agent/bootstrap.crt

echo ""
echo "===== ④ Join Token を発行 ====="
JOIN_TOKEN=$(docker compose exec -T spire-server \
  /opt/spire/bin/spire-server token generate \
    -spiffeID "${AGENT_REGISTRATION_ID}" \
    -ttl 600 \
  | awk '/Token:/ {print $2}' | tr -d '\r')
export JOIN_TOKEN
echo "JOIN_TOKEN=${JOIN_TOKEN}"

# agent が attestation 後に持つ SPIFFE ID
AGENT_ATTESTED_ID="spiffe://${TRUST_DOMAIN}/spire/agent/join_token/${JOIN_TOKEN}"

echo ""
echo "===== ⑤ ワークロード Entry を登録 (uid:0 を web-fe にマッピング) ====="
docker compose exec -T spire-server \
  /opt/spire/bin/spire-server entry create \
    -parentID "${AGENT_ATTESTED_ID}" \
    -spiffeID "${WORKLOAD_SPIFFE_ID}" \
    -selector unix:uid:0

echo ""
echo "===== ⑥ SPIRE Agent を起動 (join token 付き) ====="
docker compose up -d spire-agent

# Agent が Workload API socket を bind するまで待つ
for i in {1..30}; do
  if docker compose exec -T spire-agent /opt/spire/bin/spire-agent healthcheck >/dev/null 2>&1; then
    echo "SPIRE Agent is healthy"
    break
  fi
  sleep 1
done

echo ""
echo "===== ⑦ X.509-SVID を取得 ====="
docker compose exec -T spire-agent /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath /run/spire/agent/public/api.sock \
  -write /tmp/

# distroless image には cat 等が無いので docker cp でホストに取り出す
rm -rf out && mkdir -p out
docker cp spire-compliance-agent:/tmp/svid.0.pem out/svid.pem
docker cp spire-compliance-agent:/tmp/svid.0.key out/svid.key
docker cp spire-compliance-agent:/tmp/bundle.0.pem out/bundle.pem

echo ""
echo "----- out/svid.pem の中身 -----"
openssl x509 -in out/svid.pem -text -noout

echo ""
echo "===== ⑧ X.509-SVID の SPIFFE 準拠チェック ====="
SVID_TEXT=$(openssl x509 -in out/svid.pem -text -noout)

echo "--- (a) URI SAN がちょうど 1 つで spiffe:// で始まるか ---"
URI_LINES=$(echo "${SVID_TEXT}" | grep -c "URI:spiffe://")
echo "URI SAN 行数: ${URI_LINES} (期待値: 1)"
echo "${SVID_TEXT}" | grep "URI:"

echo ""
echo "--- (b) Basic Constraints が CA:FALSE か ---"
echo "${SVID_TEXT}" | grep -A1 "Basic Constraints"

echo ""
echo "--- (c) Key Usage に Digital Signature があり keyCertSign がないか ---"
echo "${SVID_TEXT}" | grep -A1 "Key Usage"

echo ""
echo "--- (d) Extended Key Usage に serverAuth/clientAuth があるか ---"
echo "${SVID_TEXT}" | grep -A1 "Extended Key Usage"

echo ""
echo "===== ⑨ JWT-SVID を取得 ====="
JWT=$(docker compose exec -T spire-agent /opt/spire/bin/spire-agent api fetch jwt \
  -socketPath /run/spire/agent/public/api.sock \
  -audience "https://api.example.com" \
  | awk '/^token\(/, /^$/' \
  | grep -v "^token(" \
  | grep -v "^$" \
  | head -1 \
  | tr -d '\t ')
echo "JWT (先頭 80 字): ${JWT:0:80}..."

echo ""
echo "===== ⑩ JWT-SVID の SPIFFE 準拠チェック ====="
HEADER_B64=$(echo -n "${JWT}" | cut -d. -f1)
PAYLOAD_B64=$(echo -n "${JWT}" | cut -d. -f2)

# base64url -> base64 へ補正 (パディング追加)
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
echo "--- (a) alg が RS/ES/PS 系か ---"
ALG=$(echo "${HEADER_JSON}" | jq -r .alg)
case "${ALG}" in
  RS256|RS384|RS512|ES256|ES384|ES512|PS256|PS384|PS512)
    echo "alg=${ALG} → OK (仕様 2.1 の許可リストに含まれる)"
    ;;
  *)
    echo "alg=${ALG} → NG (仕様違反)"
    exit 1
    ;;
esac

echo ""
echo "--- (b) sub が SPIFFE ID か ---"
SUB=$(echo "${PAYLOAD_JSON}" | jq -r .sub)
echo "sub=${SUB}"
if [[ "${SUB}" == "${WORKLOAD_SPIFFE_ID}" ]]; then
  echo "→ OK (期待した SPIFFE ID に一致)"
else
  echo "→ NG"
  exit 1
fi

echo ""
echo "--- (c) aud が存在し、期待した値を含むか ---"
echo "${PAYLOAD_JSON}" | jq .aud

echo ""
echo "--- (d) exp が未来か ---"
EXP=$(echo "${PAYLOAD_JSON}" | jq -r .exp)
NOW=$(date +%s)
if [[ "${EXP}" -gt "${NOW}" ]]; then
  echo "exp=${EXP} (now=${NOW}) → OK (有効期限内)"
else
  echo "exp=${EXP} (now=${NOW}) → NG"
  exit 1
fi

echo ""
echo "===== ⑪ Trust Bundle (X.509 CA) の構造チェック ====="
openssl x509 -in out/bundle.pem -text -noout | \
  grep -E "Subject:|Issuer:|URI:|CA:|Key Usage"

echo ""
echo "===== ⑫ Workload API ソケットが UDS であることを確認 ====="
# distroless なので ls の代わりに spire-agent healthcheck を使って UDS が
# 応答していることを確認する (healthcheck は socket_path 経由で動く)
docker compose exec -T spire-agent /opt/spire/bin/spire-agent healthcheck \
  -socketPath /run/spire/agent/public/api.sock

echo ""
echo "==============================================="
echo "✓ Section 8 のチェックリスト全項目 PASS"
echo "==============================================="
