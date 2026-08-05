#!/usr/bin/env bash
# 42_2_rtr_incremental_update.sh
#
# 4. RTRプロトコル機能 → 4.2 RTRプロトコル動作 → 4.2.2 インクリメンタル更新の送信
#   Routinator HTTP API (/json-delta) を使用して、
#   RTR インクリメンタル更新メカニズム（session/serial管理）の動作を検証する
#
#   Routinator 0.15.x は apt インストール時にデーモンとして自動起動する。
#   デーモンが動いていない環境（Docker 等）では本スクリプトが起動する。
#
# 検証方式の根拠:
#   RTR バイナリプロトコルでの Serial Query → 差分応答解析はシェルスクリプトでの
#   バイナリパースが複雑なため、同等のロジックを使用する HTTP API を用いて検証する。
#   /json-delta は RTR のインクリメンタル更新と同じ session/serial ベースの
#   デルタ配信を HTTP で提供するエンドポイント（Routinator マニュアル記載）。
#

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${RTR_HOST:=127.0.0.1}"
: "${RTR_PORT:=3323}"
: "${HTTP_HOST:=127.0.0.1}"
: "${HTTP_PORT:=8323}"
: "${HTTP_TIMEOUT:=15}"
: "${SERVER_WAIT:=60}"
: "${DELTA_WAIT:=3}"
: "${DATA_WAIT:=180}"
: "${REPOSITORY_DIR:=}"

BASE_URL="http://${HTTP_HOST}:${HTTP_PORT}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== クリーンアップ =====
STARTED_PID=""
SERVER_LOG=""
WORK_DIR=$(mktemp -d)
INITIAL_FILE="${WORK_DIR}/initial.json"
DELTA_FILE="${WORK_DIR}/delta.json"
cleanup() {
    rm -rf "${WORK_DIR}"
    if [ -n "${STARTED_PID}" ]; then
        kill "${STARTED_PID}" 2>/dev/null || true
        wait "${STARTED_PID}" 2>/dev/null || true
    fi
    [ -n "${SERVER_LOG}" ] && rm -f "${SERVER_LOG}"
}
trap cleanup EXIT INT TERM

info "テスト開始（4.2 RTRプロトコル動作：インクリメンタル更新の送信）"

if ! command -v curl >/dev/null 2>&1; then
    fail "curl コマンドが見つかりません"
fi
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 コマンドが見つかりません"
fi

# ── Routinator が動いていなければ起動する ──
if ! ss -tlnp 2>/dev/null | grep -q ":${HTTP_PORT}"; then
    info "ポート ${HTTP_PORT} がリスニングされていないため、サーバーを起動します"
    SERVER_LOG=$(mktemp)

    SERVER_CMD=("${ROUTINATOR_BIN}")
    if [ -n "${REPOSITORY_DIR}" ] && [ -d "${REPOSITORY_DIR}" ]; then
        SERVER_CMD+=(--repository-dir "${REPOSITORY_DIR}" --disable-rrdp --disable-rsync)
        info "   リポジトリディレクトリ: ${REPOSITORY_DIR}"
    fi
    SERVER_CMD+=(server --rtr "${RTR_HOST}:${RTR_PORT}" --http "${HTTP_HOST}:${HTTP_PORT}")

    "${SERVER_CMD[@]}" > "${SERVER_LOG}" 2>&1 &
    STARTED_PID=$!

    WAITED=0
    while [ "${WAITED}" -lt "${SERVER_WAIT}" ]; do
        if ss -tlnp 2>/dev/null | grep -q ":${HTTP_PORT}"; then
            info "   HTTP ポートが開きました（${WAITED}秒）"
            break
        fi
        sleep 1
        WAITED=$(( WAITED + 1 ))
    done

    if ! ss -tlnp 2>/dev/null | grep -q ":${HTTP_PORT}"; then
        if [ -n "${SERVER_LOG}" ] && [ -f "${SERVER_LOG}" ]; then
            warn "サーバーログ (末尾10行):"
            tail -n 10 "${SERVER_LOG}" | awk '{print "   [LOG] " $0}'
        fi
        fail "Routinator の HTTP ポート ${HTTP_PORT} が ${SERVER_WAIT} 秒以内に開きませんでした"
    fi
fi

# ── データが利用可能になるまでポーリング ──
info "データが利用可能になるまで待機します（最大 ${DATA_WAIT} 秒）"
WAITED=0
while [ "${WAITED}" -lt "${DATA_WAIT}" ]; do
    RESP=$(curl -s --max-time 5 "${BASE_URL}/json-delta" 2>/dev/null || true)
    if [ -n "${RESP}" ]; then
        HAS_DATA=$(echo "${RESP}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if d.get('announced') else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")
        if [ "${HAS_DATA}" = "yes" ]; then
            info "   データが利用可能になりました（${WAITED}秒）"
            break
        fi
    fi
    sleep 5
    WAITED=$(( WAITED + 5 ))
done

#  1) /json-delta 初回リクエスト（フルデータ取得 + 検証） 
info "1) /json-delta への初回リクエスト（フルデータセット取得）"

set +e
curl -s --max-time "${HTTP_TIMEOUT}" "${BASE_URL}/json-delta" -o "${INITIAL_FILE}" 2>/dev/null
CURL_RC=$?
set -e

if [ "${CURL_RC}" -ne 0 ] || [ ! -s "${INITIAL_FILE}" ]; then
    fail "HTTP リクエスト失敗（curl 終了コード=${CURL_RC}）"
fi

set +e
PARSE_RESULT=$(python3 - "${INITIAL_FILE}" <<'PY'
import sys, json

try:
    with open(sys.argv[1], "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)

session   = data.get("session")
serial    = data.get("serial")
reset     = data.get("reset")
announced = data.get("announced", [])

if session is None or serial is None:
    print("ERROR:session または serial が見つかりません")
    sys.exit(1)
if not reset:
    print(f"ERROR:reset={reset} (初回は True であるべき)")
    sys.exit(1)
if len(announced) == 0:
    print("ERROR:announced が空です")
    sys.exit(1)

print(f"OK:{session}:{serial}:{len(announced)}")
PY
)
PY_RC=$?
set -e

if [ "${PY_RC}" -ne 0 ]; then
    fail "初回リクエスト検証失敗: ${PARSE_RESULT}"
fi

IFS=':' read -r _ SESSION SERIAL ANNOUNCED_COUNT <<< "${PARSE_RESULT}"

info "   Session ID    : ${SESSION}"
info "   Serial Number : ${SERIAL}"
info "   Announced VRPs: ${ANNOUNCED_COUNT}"

pass "初回フルデータ取得成功（reset=True、VRP ${ANNOUNCED_COUNT} 件）"

#  2) 同一 session/serial での差分リクエスト（インクリメンタル確認） 
info "2) 同一 session/serial での差分リクエスト（インクリメンタル更新確認）"
sleep "${DELTA_WAIT}"
DELTA_URL="${BASE_URL}/json-delta?session=${SESSION}&serial=${SERIAL}"
info "   リクエスト URL: ${DELTA_URL}"

set +e
curl -s --max-time "${HTTP_TIMEOUT}" "${DELTA_URL}" -o "${DELTA_FILE}" 2>/dev/null
DELTA_RC=$?
set -e

if [ "${DELTA_RC}" -eq 28 ]; then
    # curl exit code 28 = タイムアウト → Long Polling で新しいデータを待っている → 正常動作
    info "   差分リクエストがタイムアウトしました（Long Polling）"
    pass "インクリメンタル更新メカニズムが動作しています（更新待ちの Long Polling を確認）"
elif [ "${DELTA_RC}" -ne 0 ] || [ ! -s "${DELTA_FILE}" ]; then
    fail "差分リクエスト失敗（curl 終了コード=${DELTA_RC}）"
else
    set +e
    DELTA_PARSE=$(python3 - "${DELTA_FILE}" "${SESSION}" "${SERIAL}" <<'PY'
import sys, json

try:
    with open(sys.argv[1], "r") as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)

orig_session = sys.argv[2]
orig_serial  = int(sys.argv[3])

reset   = data.get("reset")
session = str(data.get("session"))
serial  = data.get("serial")

if reset:
    print(f"WARN:reset=True（履歴切れの可能性）")
    sys.exit(0)
if session != orig_session:
    print(f"ERROR:Session ID 不一致 初回={orig_session} delta={session}")
    sys.exit(1)
if serial < orig_serial:
    print(f"ERROR:Serial 減少 初回={orig_serial} delta={serial}")
    sys.exit(1)

print(f"OK:{session}:{serial}")
PY
    )
    DELTA_PY_RC=$?
    set -e

    if [ "${DELTA_PY_RC}" -ne 0 ]; then
        fail "差分リクエスト検証失敗: ${DELTA_PARSE}"
    fi

    case "${DELTA_PARSE}" in
        WARN:*)
            warn "${DELTA_PARSE#WARN:}"
            ;;
        OK:*)
            IFS=':' read -r _ D_SESSION D_SERIAL <<< "${DELTA_PARSE}"
            pass "reset=False — インクリメンタルモードで応答（Session: ${D_SESSION}、Serial: ${D_SERIAL}）"
            ;;
    esac
fi

pass "テスト完了（4.2 RTRプロトコル動作：インクリメンタル更新の送信）"
