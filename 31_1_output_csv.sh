#!/usr/bin/env bash

set -euo pipefail #コマンド失敗か未定義変数の使用でスクリプトを停止、パイプラインだと全体を停止



# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_OUT_DIR:=./routinator-csv-out}"
: "${RPKI_LOG_FILE:=./31_1_output_csv.log}"
: "${CSV_OUTPUT_FILE:=${RPKI_OUT_DIR}/vrps.csv}"

# ===== 表示用ヘルパ =====

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（3.1 VRP出力形式：CSV形式での出力テスト）"



if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi



mkdir -p "${RPKI_OUT_DIR}"
: > "${RPKI_LOG_FILE}"
rm -f "${CSV_OUTPUT_FILE}"

info "1) ディレクトリの準備"

if [ -d "${EXISTING_CACHE_DIR}" ]; then
    pass "既存キャッシュを使用します: ${EXISTING_CACHE_DIR}"
else
    fail "キャッシュディレクトリが見つかりません: ${EXISTING_CACHE_DIR}"
fi

info "キャッシュディレクトリ: ${EXISTING_CACHE_DIR}"
info "出力ディレクトリ      : ${RPKI_OUT_DIR}"

info "2) CSV形式でVRPリストを出力します"


set +e
"${ROUTINATOR_BIN}" \
    --repository-dir "${EXISTING_CACHE_DIR}" \
    --disable-rrdp \
    --disable-rsync \
    vrps \
    --format csv \
    --output "${CSV_OUTPUT_FILE}" \
    > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
    warn "ログ出力:"
    cat "${RPKI_LOG_FILE}"
    fail "Routinator の実行が失敗しました（RC=${RC}）。"
fi
pass "Routinator の実行が完了しました"


info "3) 生成されたCSVファイルを検証します"

# A. ファイルが存在し、サイズが0より大きいか
if [ -s "${CSV_OUTPUT_FILE}" ]; then
    pass "出力ファイルが存在し、データが含まれています"
else
    fail "出力ファイルが見つからないか、サイズが0です: ${CSV_OUTPUT_FILE}"
fi

# B. CSV形式か（ヘッダにカンマが含まれているか）

HEAD_LINE=$(head -n 1 "${CSV_OUTPUT_FILE}")

info "ヘッダ行確認: ${HEAD_LINE}"

if echo "${HEAD_LINE}" | grep -q ","; then
    pass "CSV形式の出力を確認しました（カンマ区切りを検出）"
else
    fail "CSV形式に見えません（ヘッダ行にカンマがありません）"
fi

pass "テスト完了（3.1-1 CSV形式での出力テスト）"