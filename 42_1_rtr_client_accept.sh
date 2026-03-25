#!/usr/bin/env bash
# 42_1_rtr_client_accept.sh
#
# 4. RTRプロトコル機能 → 4.2 RTRプロトコル動作 → 4.2.1 クライアント接続の受け入れ
#   RTR プロトコル (RFC 8210) の Reset Query を送信し、
#   Cache Response を正しく受信できるか検証する
#
#   Routinator 0.15.x は apt インストール時にデーモンとして自動起動する。
#   デーモンが動いていない環境（Docker 等）では本スクリプトが起動する。
#

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${RTR_HOST:=127.0.0.1}"
: "${RTR_PORT:=3323}"
: "${HTTP_HOST:=127.0.0.1}"
: "${HTTP_PORT:=8323}"
: "${RTR_TIMEOUT:=10}"
: "${SERVER_WAIT:=60}"
: "${DATA_WAIT:=180}"
: "${REPOSITORY_DIR:=}"
RESPONSE_FILE=$(mktemp)

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== クリーンアップ =====
STARTED_PID=""
SERVER_LOG=""
cleanup() {
    rm -f "${RESPONSE_FILE}"
    if [ -n "${STARTED_PID}" ]; then
        kill "${STARTED_PID}" 2>/dev/null || true
        wait "${STARTED_PID}" 2>/dev/null || true
    fi
    [ -n "${SERVER_LOG}" ] && rm -f "${SERVER_LOG}"
}
trap cleanup EXIT INT TERM

info "テスト開始（4.2 RTRプロトコル動作：クライアント接続の受け入れ）"

if ! command -v nc >/dev/null 2>&1; then
    fail "nc (netcat) コマンドが見つかりません"
fi

# ── Routinator が動いていなければ起動する ──
if ! ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
    info "ポート ${RTR_PORT} がリスニングされていないため、サーバーを起動します"
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
        if ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
            info "   RTR ポートが開きました（${WAITED}秒）"
            break
        fi
        sleep 1
        WAITED=$(( WAITED + 1 ))
    done

    if ! ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
        if [ -n "${SERVER_LOG}" ] && [ -f "${SERVER_LOG}" ]; then
            warn "サーバーログ (末尾10行):"
            tail -n 10 "${SERVER_LOG}" | awk '{print "   [LOG] " $0}'
        fi
        fail "Routinator の RTR ポート ${RTR_PORT} が ${SERVER_WAIT} 秒以内に開きませんでした"
    fi
fi

# ── データが利用可能になるまでポーリング ──
info "データが利用可能になるまで待機します（最大 ${DATA_WAIT} 秒）"
WAITED=0
while [ "${WAITED}" -lt "${DATA_WAIT}" ]; do
    RESP=$(curl -s --max-time 5 "http://${HTTP_HOST}:${HTTP_PORT}/json-delta" 2>/dev/null || true)
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

#  1) RTR Reset Query (v1) の送信と Cache Response の確認 
#
# RFC 8210 - Reset Query PDU:
#   Protocol Version : 0x01 (v1)
#   PDU Type         : 0x02 (Reset Query)
#   Session ID       : 0x0000 (未使用)
#   Length           : 0x00000008 (8 bytes)
#
info "1) RTR Reset Query (v1) を送信し、Cache Response を確認"

set +e
printf '\x01\x02\x00\x00\x00\x00\x00\x08' \
    | nc -w "${RTR_TIMEOUT}" "${RTR_HOST}" "${RTR_PORT}" \
    > "${RESPONSE_FILE}" 2>/dev/null
NC_RC=$?
set -e

if [ "${NC_RC}" -ne 0 ] && [ ! -s "${RESPONSE_FILE}" ]; then
    fail "RTR サーバーへの接続に失敗しました（nc 終了コード=${NC_RC}）"
fi

RESP_SIZE=$(wc -c < "${RESPONSE_FILE}" 2>/dev/null || echo 0)
info "   受信データサイズ: ${RESP_SIZE} bytes"

if [ "${RESP_SIZE}" -lt 8 ]; then
    fail "応答が不足しています（${RESP_SIZE} bytes < 最小 8 bytes）"
fi

# 先頭 PDU のヘッダ検証: [Version=1][Type=3(Cache Response)]
RESP_VERSION=$(od -An -tu1 -N1 -j0 "${RESPONSE_FILE}" 2>/dev/null | tr -d ' ')
RESP_TYPE=$(od -An -tu1 -N1 -j1 "${RESPONSE_FILE}" 2>/dev/null | tr -d ' ')

if [ "${RESP_VERSION}" != "1" ]; then
    fail "Protocol Version が v1 ではありません: ${RESP_VERSION}"
fi

if [ "${RESP_TYPE}" != "3" ]; then
    fail "PDU Type が Cache Response (3) ではありません: ${RESP_TYPE}"
fi

SESSION_ID_HEX=$(od -An -t x1 -N2 -j2 "${RESPONSE_FILE}" | tr -d ' \n')
SESSION_ID=$(( 0x${SESSION_ID_HEX:-0} ))

pass "Cache Response (v1) を受信しました（Session ID: ${SESSION_ID}）"

#  2) End of Data PDU の確認 
info "2) End of Data PDU の確認"

# v1 の End of Data は 24 bytes:
#   [Ver(1)][Type=0x07(1)][SessionID(2)][Len=24(4)][Serial(4)][Refresh(4)][Retry(4)][Expire(4)]

if [ "${RESP_SIZE}" -lt 24 ]; then
    fail "応答サイズが小さく End of Data PDU の確認ができません（${RESP_SIZE} bytes）"
fi

EOD_OFFSET=$(( RESP_SIZE - 24 ))
EOD_TYPE=$(od -An -tu1 -N1 -j$(( EOD_OFFSET + 1 )) "${RESPONSE_FILE}" 2>/dev/null | tr -d ' ')

if [ "${EOD_TYPE}" != "7" ]; then
    fail "末尾に End of Data PDU が見つかりません（Type=${EOD_TYPE}、期待値: 7）"
fi

#binaryから数値取得
HEX_VAL=$(od -An -t x1 -N4 -j$(( EOD_OFFSET + 8 )) "${RESPONSE_FILE}" | tr -d ' \n')
SERIAL_NUM=$(( 0x${HEX_VAL:-0} ))

pass "End of Data PDU を確認しました（Serial: ${SERIAL_NUM}、Session ID: ${SESSION_ID}）"

#  3) VRP データの存在確認 
info "3) VRP データの存在確認"

# Cache Response(8B) と End of Data(24B) の間にデータがあれば VRP が含まれている
VRP_DATA_SIZE=$(( RESP_SIZE - 8 - 24 ))

if [ "${VRP_DATA_SIZE}" -gt 0 ]; then
    pass "VRP データが含まれています（${VRP_DATA_SIZE} bytes）"
elif [ "${SERIAL_NUM}" -eq 0 ]; then
    warn "VRP データなし（Serial=0: 初回検証が未完了の可能性があります）"
    warn "※ TA 証明書の有効期限やネットワーク環境を確認してください"
else
    fail "VRP データが含まれていません（Serial=${SERIAL_NUM}）"
fi

pass "テスト完了（4.2 RTRプロトコル動作：クライアント接続の受け入れ）"
