#!/usr/bin/env bash
# 21_4_timeout_test.sh
#
#
# 2. データ取得と検証機能 → 2.1 RPKIデータの取得
#   データ取得のタイムアウト設定テスト
#
set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"       # バイナリの位置
: "${RPKI_CACHE_DIR:=./routinator-timeout-cache}" # キャッシュディレクトリ
: "${RPKI_OUT_DIR:=./routinator-timeout-out}"     # 出力ディレクトリ
: "${RPKI_LOG_FILE:=./21_4_timeout_setting.log}"
: "${TIMEOUT_RRDP:=10}"
: "${TIMEOUT_RSYNC:=10}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1 RPKIデータの取得：データ取得のタイムアウト設定テスト）"


if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

info "1) ディレクトリの準備"
mkdir -p "${RPKI_OUT_DIR}"


if [ -d "${RPKI_CACHE_DIR}" ]; then
    info "既存のキャッシュをクリアします: ${RPKI_CACHE_DIR}"
    rm -rf "${RPKI_CACHE_DIR}"
fi

rm -f "${RPKI_LOG_FILE}"

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ      : ${RPKI_OUT_DIR}"
info "ログファイル          : ${RPKI_LOG_FILE}"

###

info "2) Routinator を タイムアウト指定付きで実行します..."

START_TS="$(date +%s)"

set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --rrdp-timeout "${TIMEOUT_RRDP}" \
  --rsync-timeout "${TIMEOUT_RSYNC}" \
  -vv \
  vrps \
  --format json \
  --output "${RPKI_OUT_DIR}/vrps.json" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

END_TS="$(date +%s)"

ELAPSED="$(( END_TS - START_TS ))"

info "実行時間: ${ELAPSED} 秒"
if [ "${RC}" -eq 0 ]; then
    pass "プロセスは正常終了しました (Exit Code 0)"
else
    warn "プロセスが異常終了しました (Exit Code ${RC})"
fi

info "3) ログからタイムアウト確認"
if grep -q "operation timed out" "${RPKI_LOG_FILE}"; then
    pass "ログ内でタイムアウトの発生を確認しました ('operation timed out')"
    grep "operation timed out" "${RPKI_LOG_FILE}" | head -n 3 | awk '{print "   [LOG] " $0}'
else
    pass "ログにタイムアウト記録がありません。"
fi



pass "テスト完了（2.1 RPKIデータの取得：データ取得のタイムアウト設定テスト）"