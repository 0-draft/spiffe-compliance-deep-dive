# spiffe-compliance-deep-dive

Verify in one shot that the SVIDs SPIRE issues actually conform to the SPIFFE spec.

The companion write-up walks through the spec (SPIFFE-ID, X.509-SVID, JWT-SVID, Workload API, Trust Bundle) and lists every MUST / MUST NOT requirement. This repo is the runnable part: it boots SPIRE locally, fetches real SVIDs, and checks each requirement with `openssl` and `jq`.

## Run it

```bash
git clone https://github.com/0-draft/spiffe-compliance-deep-dive.git
cd spiffe-compliance-deep-dive
bash run.sh
```

You need Docker (Desktop, Rancher Desktop, OrbStack, anything that gives you `docker compose`), plus `jq` and `openssl`. Takes about a minute.

`run.sh` always finishes with `docker compose down -v`, even on Ctrl+C, so nothing is left behind.

Verified on macOS 14 + Rancher Desktop with SPIRE pinned to `v1.14.6` in `docker-compose.yml`.

## What it checks

1. Boot SPIRE Server
2. Export its trust bundle and feed it to the Agent
3. Generate a join token
4. Register one workload entry: `unix:uid:0` -> `spiffe://example.org/payments/web-fe`
5. Boot the SPIRE Agent
6. Fetch an X.509-SVID, pull it to the host with `docker cp`
7. Inspect it with `openssl x509 -text` and check URI SAN, Basic Constraints, Key Usage, EKU
8. Fetch a JWT-SVID and Base64URL-decode header + payload
9. Check `alg` / `sub` / `aud` / `exp`
10. Open the Trust Bundle CA cert, confirm self-signed with a path-less SPIFFE ID
11. Run `spire-agent healthcheck` to confirm the Workload API UDS is alive
12. Tear everything down

## What a passing X.509-SVID looks like

```text
X509v3 Key Usage: critical
    Digital Signature, Key Encipherment, Key Agreement
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Subject Alternative Name:
    URI:spiffe://example.org/payments/web-fe
```

## What a passing JWT-SVID looks like

Header:

```json
{
  "alg": "ES256",
  "kid": "...",
  "typ": "JWT"
}
```

Payload:

```json
{
  "aud": ["https://api.example.com"],
  "exp": 1778672723,
  "iat": 1778672423,
  "sub": "spiffe://example.org/payments/web-fe"
}
```

Both line up 1:1 with the spec (X509-SVID section 4, JWT-SVID section 3).

## Layout

```text
run.sh                   # 12-step verification script
docker-compose.yml       # SPIRE Server + Agent
server/server.conf       # self-signed CA, sqlite, join_token attestor
agent/agent.conf         # unix workload attestor
```

## Things that bit me

- **The SPIRE images are distroless.** No `cat`, no `ls`, no shell. The script pulls SVIDs out with `docker cp` and confirms the UDS by running `spire-agent healthcheck` from inside the container.
- **Named volumes are root-owned.** Mounting one at `/var/lib/spire/server/.data` crashes the server because the spire user (uid 1000) can't write to it. The script avoids persistence entirely and lets data live in the container's writable layer. For production, add an init container that chowns the volume.
- **`/spire/...` is reserved.** Passing `-spiffeID spiffe://<td>/spire/...` to `spire-server token generate` is rejected. Use any other path (e.g. `/myagent`). After the agent attests, its real SPIFFE ID becomes `spiffe://<td>/spire/agent/join_token/<token>`, and that string is what you pass as `-parentID` when registering workload entries.

## Reusing the checks elsewhere

Steps 8 through 11 of `run.sh` are pure `openssl` / `jq` / `bash`. If you suspect another implementation that claims SPIFFE compliance, point those same checks at its PEM / JWT / bundle JSON. The source of the SVID doesn't matter.

## License

MIT. SPIFFE and SPIRE have their own licenses; see the upstream repos.
