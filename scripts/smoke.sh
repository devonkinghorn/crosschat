#!/usr/bin/env bash
# End-to-end smoke test:
#   1. crosschatd starts a bundled Tuwunel homeserver (private mode) and the
#      Google Messages bridge (downloaded from upstream, checksum-verified),
#   2. registers a user with the vault's registration token,
#   3. runs crosschat-core's login/send/thread/sync/restore test,
#   4. checks bridge health and calls the provisioning proxy with the user's
#      Matrix token.
#
# Usage: TUWUNEL_BIN=/path/to/tuwunel scripts/smoke.sh [--keep]
# Optional env: SMOKE_DIR, SMOKE_BRIDGES ("gmessages slack imessage groupme"),
#               SMOKE_USER, SMOKE_PASS, API_PORT, HS_PORT
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SMOKE_DIR:-$ROOT/smoke}"
TUWUNEL_BIN="${TUWUNEL_BIN:?set TUWUNEL_BIN to a tuwunel binary}"
HS_PORT="${HS_PORT:-6167}"
API_PORT="${API_PORT:-29300}"
SERVER_NAME="crosschat.test"
USER="${SMOKE_USER:-smoke$RANDOM}"
PASS="${SMOKE_PASS:-smoke-pass-$RANDOM$RANDOM}"
USER2="${USER}b"
PASS2="$PASS-b"
BRIDGES="${SMOKE_BRIDGES:-gmessages}"

rm -rf "$WORK" && mkdir -p "$WORK"
{
  echo "listen = \"127.0.0.1:$API_PORT\""
  echo "data_dir = \"data\""
  echo "manifests_dir = \"$ROOT/manifests\""
  echo "[homeserver]"
  echo "url = \"http://127.0.0.1:$HS_PORT\""
  echo "server_name = \"$SERVER_NAME\""
  echo "registration = { kind = \"manual\" }"
  echo "[homeserver.bundled]"
  echo "binary = \"$TUWUNEL_BIN\""
  echo "port = $HS_PORT"
  echo "federation = false"
  echo "allow_registration = true"
  echo "[auth]"
  echo "admins = [\"@$USER:$SERVER_NAME\"]"
  for b in $BRIDGES; do echo "[bridges.$b]"; echo "enabled = true"; done
} > "$WORK/crosschatd.toml"

cargo build -q -p crosschatd --manifest-path "$ROOT/Cargo.toml"
"$ROOT/target/debug/crosschatd" run -c "$WORK/crosschatd.toml" > "$WORK/crosschatd.log" 2>&1 &
DPID=$!
cleanup() {
  if [[ "${1:-}" != "--keep" ]]; then kill -INT $DPID 2>/dev/null || true; wait $DPID 2>/dev/null || true; fi
}
trap 'cleanup' EXIT

echo "waiting for crosschatd + homeserver..."
for i in $(seq 1 180); do
  curl -fsS "http://127.0.0.1:$API_PORT/_crosschat/v1/health" >/dev/null 2>&1 && break
  kill -0 $DPID 2>/dev/null || { cat "$WORK/crosschatd.log"; exit 1; }
  sleep 1
done
curl -fsS "http://127.0.0.1:$HS_PORT/_matrix/client/versions" >/dev/null

TOKEN=$(python3 -c "import json;print(json.load(open('$WORK/data/vault.json'))['hs_registration_token'])")
register() {
  python3 - "$@" <<PY
import json, urllib.request, sys
url = "http://127.0.0.1:$HS_PORT/_matrix/client/v3/register"
def post(body):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        return json.load(e)
body = {"username": sys.argv[1], "password": sys.argv[2], "inhibit_login": False}
r = post(body)
session = r.get("session")
body["auth"] = {"type": "m.login.registration_token", "token": "$TOKEN", "session": session}
r = post(body)
if "access_token" not in r:
    # Some servers require the dummy stage after the token stage.
    body["auth"] = {"type": "m.login.dummy", "session": session}
    r = post(body)
assert "access_token" in r, r
print(r["access_token"])
PY
}
ACCESS=$(register "$USER" "$PASS")
register "$USER2" "$PASS2" >/dev/null
echo "registered @$USER:$SERVER_NAME and @$USER2:$SERVER_NAME"

echo "== crosschat-core smoke test"
CROSSCHAT_SMOKE_HS="http://127.0.0.1:$HS_PORT" CROSSCHAT_SMOKE_USER="$USER" CROSSCHAT_SMOKE_PASSWORD="$PASS" \
  CROSSCHAT_SMOKE_USER2="$USER2" CROSSCHAT_SMOKE_PASSWORD2="$PASS2" \
  cargo test -q -p crosschat-core --manifest-path "$ROOT/Cargo.toml" --test smoke -- --nocapture

echo "== bridges"
for b in $BRIDGES; do
  for i in $(seq 1 60); do
    LIVE=$(curl -fsS -H "Authorization: Bearer $ACCESS" "http://127.0.0.1:$API_PORT/_crosschat/v1/networks" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); b=[x for x in d['bridges'] if x['id']=='$b'][0]; print((b.get('health') or {}).get('live'), b['process']['state'] if b['process'] else None, b.get('setup_error'))")
    [[ "$LIVE" == True\ running* ]] && break
    sleep 2
  done
  echo "$b: live/process/setup_error = $LIVE"
  [[ "$LIVE" == True\ running* ]] || { tail -50 "$WORK/data/bridges/$b/bridge.log" || true; exit 1; }
  echo "$b login flows via provisioning proxy:"
  curl -fsS -H "Authorization: Bearer $ACCESS" "http://127.0.0.1:$API_PORT/_crosschat/v1/bridges/$b/provision/v3/login/flows"; echo
  echo "$b whoami via provisioning proxy:"
  curl -fsS -H "Authorization: Bearer $ACCESS" "http://127.0.0.1:$API_PORT/_crosschat/v1/bridges/$b/provision/v3/whoami" | head -c 600; echo
done
echo "== unauthenticated proxy call is rejected:"
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:$API_PORT/_crosschat/v1/bridges/gmessages/provision/v3/whoami"
echo "SMOKE OK"
cleanup "${1:-}"
trap - EXIT
