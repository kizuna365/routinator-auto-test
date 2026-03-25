#!/usr/bin/env bash
# 41_1_rtr_server_running.sh
#
# 4. RTRサーバー機能 → 4.1 RTRサーバーの起動 → 4.1.1 RTRサーバー起動確認
#   Routinator がサーバーモードで稼働しているか確認する
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
: "${SERVER_WAIT:=5}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== クリーンアップ =====
STARTED_PID=""
LOG_FILE=""
cleanup() {
    if [ -n "${STARTED_PID}" ]; then
        kill "${STARTED_PID}" 2>/dev/null || true
        wait "${STARTED_PID}" 2>/dev/null || true
    fi
    [ -n "${LOG_FILE}" ] && rm -f "${LOG_FILE}"
}
trap cleanup EXIT INT TERM

info "テスト開始（4.1 RTRサーバー起動：RTRサーバー起動確認）"

# ──────────────────────────────────────
#  1) サービスの稼働状態確認
#     既にリスニング中ならそのまま、そうでなければ起動する
# ──────────────────────────────────────
info "1) サービスの稼働状態確認"

if ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
    info "   ポート ${RTR_PORT} で既にリスニング中です"
else
    info "   ポート ${RTR_PORT} がリスニングされていないため、サーバーを起動します"
    LOG_FILE=$(mktemp)
    "${ROUTINATOR_BIN}" server \
        --rtr "${RTR_HOST}:${RTR_PORT}" \
        --http "${HTTP_HOST}:${HTTP_PORT}" \
        > "${LOG_FILE}" 2>&1 &
    STARTED_PID=$!

    WAITED=0
    while [ "${WAITED}" -lt "${SERVER_WAIT}" ]; do
        if ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
            break
        fi
        sleep 1
        WAITED=$(( WAITED + 1 ))
    done
fi

if pgrep -x routinator >/dev/null 2>&1; then
    pass "Routinator プロセスが稼働中です"
else
    fail "Routinator プロセスが稼働していません"
fi

# ──────────────────────────────────────
#  2) server モードでの起動確認
# ──────────────────────────────────────
info "2) server モードでの起動確認"

SERVER_FOUND=false
for PID in $(pgrep -x routinator 2>/dev/null); do
    CMDLINE=$(tr '\0' ' ' < /proc/"${PID}"/cmdline 2>/dev/null || echo "")
    if echo "${CMDLINE}" | grep -q "server"; then
        pass "server モードで起動しています"
        info "   コマンドライン: ${CMDLINE}"
        SERVER_FOUND=true
        break
    fi
done

if [ "${SERVER_FOUND}" = false ]; then
    fail "server モードでの起動が確認できません"
fi

# ──────────────────────────────────────
#  3) 致命的エラーの不在確認
# ──────────────────────────────────────
info "3) ログに致命的エラーがないか確認"

FATAL_LINES=""
# journalctl が使えればシステムログを確認
FATAL_LINES=$(journalctl -u routinator --no-pager -n 100 2>/dev/null \
              | grep -iE "fatal|panicked|error listening|abort" || true)
# 自前で起動した場合はログファイルも確認
if [ -n "${LOG_FILE}" ] && [ -f "${LOG_FILE}" ]; then
    FATAL_LINES="${FATAL_LINES}$(grep -iE "fatal|panicked|error listening|abort" "${LOG_FILE}" || true)"
fi

if [ -z "${FATAL_LINES}" ]; then
    pass "ログに致命的エラーはありません"
else
    warn "致命的エラーの可能性がある記録が見つかりました:"
    echo "${FATAL_LINES}" | head -n 5 | awk '{print "   [LOG] " $0}'
    fail "ログ内に致命的エラーが検出されました"
fi

pass "テスト完了（4.1 RTRサーバー起動：RTRサーバー起動確認）"
