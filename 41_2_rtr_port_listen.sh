#!/usr/bin/env bash
# 41_2_rtr_port_listen.sh
#
# 4. RTRサーバー機能 → 4.1 RTRサーバー起動 → 4.1.2 デフォルトポート3323でのリスニング確認
#   Routinator がポート 3323 で TCP リスニングしているか検証する
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

info "テスト開始（4.1 RTRサーバー起動：デフォルトポート${RTR_PORT}でのリスニング確認）"

# ── Routinator が動いていなければ起動する ──
if ! ss -tlnp 2>/dev/null | grep -q ":${RTR_PORT}"; then
    info "ポート ${RTR_PORT} がリスニングされていないため、サーバーを起動します"
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

# ──────────────────────────────────────
#  1) ss によるリスニング確認 + 設定ファイルとの照合
# ──────────────────────────────────────
info "1) ポート ${RTR_PORT} のリスニング状態と設定ファイルの照合"

if ! command -v ss >/dev/null 2>&1; then
    fail "ss コマンドが見つかりません"
fi

SS_OUTPUT=$(ss -tlnp 2>/dev/null | grep ":${RTR_PORT}" || true)

if [ -z "${SS_OUTPUT}" ]; then
    fail "ポート ${RTR_PORT} でリスニング中のソケットが見つかりません"
fi

LISTEN_ADDR=$(echo "${SS_OUTPUT}" | awk '{print $4}' | head -n 1)
info "   検出アドレス: ${LISTEN_ADDR}"

CONFIG_FILE="/etc/routinator/routinator.conf"
if [ -f "${CONFIG_FILE}" ]; then
    RTR_LISTEN_CFG=$(grep "rtr-listen" "${CONFIG_FILE}" 2>/dev/null || true)
    info "   設定値: ${RTR_LISTEN_CFG}"
fi

if echo "${LISTEN_ADDR}" | grep -q "${RTR_HOST}:${RTR_PORT}"; then
    pass "設定通り ${RTR_HOST}:${RTR_PORT} でリスニングしています"
else
    fail "リスニングアドレスが ${RTR_HOST}:${RTR_PORT} と異なります: ${LISTEN_ADDR}"
fi

# ──────────────────────────────────────
#  2) リスニングプロセスが Routinator であることの確認
# ──────────────────────────────────────
info "2) リスニングプロセスが Routinator であることの確認"

# ss -tlnp の出力からプロセス名を確認
if echo "${SS_OUTPUT}" | grep -qi "routinator"; then
    pass "ポート ${RTR_PORT} でリスニングしているプロセスは Routinator です"
else
    # ss にプロセス名が表示されない場合、pgrep で確認
    if pgrep -x routinator >/dev/null 2>&1; then
        pass "Routinator プロセスがポート ${RTR_PORT} でリスニングしています"
    else
        fail "リスニングプロセスが Routinator であることを確認できませんでした"
    fi
fi

pass "テスト完了（4.1 RTRサーバー起動：デフォルトポート${RTR_PORT}でのリスニング確認）"
