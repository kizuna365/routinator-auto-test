#!/usr/bin/env bash

set -euo pipefail #コマンド失敗か未定義変数の使用でスクリプトを停止、パイプラインだと全体を停止



# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_OUT_DIR:=./routinator-openbgpd-out}"
: "${RPKI_LOG_FILE:=./31_3_output_openbgpd.log}"
: "${OPENBGPD_OUTPUT_FILE:=${RPKI_OUT_DIR}/vrps.openbgpd}"

# ===== 表示用ヘルパ =====

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（3.1 VRP出力形式：OpenBGPD形式での出力テスト）"



if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi



mkdir -p "${RPKI_OUT_DIR}"
: > "${RPKI_LOG_FILE}"
rm -f "${OPENBGPD_OUTPUT_FILE}"

info "1) ディレクトリの準備"

if [ -d "${EXISTING_CACHE_DIR}" ]; then
    pass "既存キャッシュを使用します: ${EXISTING_CACHE_DIR}"
else
    fail "キャッシュディレクトリが見つかりません: ${EXISTING_CACHE_DIR}"
fi

info "キャッシュディレクトリ: ${EXISTING_CACHE_DIR}"
info "出力ディレクトリ      : ${RPKI_OUT_DIR}"

info "2) OpenBGPD形式でVRPリストを出力します"


set +e
"${ROUTINATOR_BIN}" \
    --repository-dir "${EXISTING_CACHE_DIR}" \
    --disable-rrdp \
    --disable-rsync \
    vrps \
    --format openbgpd \
    --output "${OPENBGPD_OUTPUT_FILE}" \
    > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
    warn "ログ出力:"
    cat "${RPKI_LOG_FILE}"
    fail "Routinator の実行が失敗しました（RC=${RC}）。"
fi
pass "Routinator の実行が完了しました"


info "3) 生成されたOpenBGPDファイルを検証します"

# A. ファイルが存在し、サイズが0より大きいか
if [ -s "${OPENBGPD_OUTPUT_FILE}" ]; then
    pass "出力ファイルが存在し、データが含まれています"
else
    fail "出力ファイルが見つからないか、サイズが0です: ${OPENBGPD_OUTPUT_FILE}"
fi

# B. OpenBGPD形式か確認

HEAD_LINE=$(head -n 1 "${OPENBGPD_OUTPUT_FILE}")

info "先頭行確認: ${HEAD_LINE}"

# roa-setブロックがある場合
if grep -q '^roa-set {' "${OPENBGPD_OUTPUT_FILE}"; then
    pass "roa-set ブロックを検出しました"
    
    # roa-set内のROAエントリ（CIDR / maxlen / source-as）が1行以上マッチするか
    ROA_ENTRY_COUNT=$(grep -cE '^\s+[0-9a-fA-F.:]+/[0-9]+ (maxlen [0-9]+ )?source-as [0-9]+' "${OPENBGPD_OUTPUT_FILE}" || true)
    : "${ROA_ENTRY_COUNT:=0}"
    info "  ROAエントリ数: ${ROA_ENTRY_COUNT}"
    
    if [ "${ROA_ENTRY_COUNT}" -gt 0 ]; then
        pass "ROAエントリが ${ROA_ENTRY_COUNT} 件検出されました"
    else
        fail "roa-set内にROAエントリが見つかりません"
    fi

# roa-setがなく、aspa-setがある場合
elif grep -q '^aspa-set {' "${OPENBGPD_OUTPUT_FILE}"; then
    pass "aspa-set ブロックを検出しました"
    
    # provider-asが存在するか
    if grep -q 'provider-as' "${OPENBGPD_OUTPUT_FILE}"; then
        PROVIDER_COUNT=$(grep -c 'provider-as' "${OPENBGPD_OUTPUT_FILE}" || echo 0)
        pass "provider-as エントリが ${PROVIDER_COUNT} 件検出されました"
    else
        fail "aspa-set内にprovider-asエントリが見つかりません"
    fi

else
    fail "OpenBGPD形式に見えません（roa-set または aspa-set が見つかりません）"
fi

pass "テスト完了（3.3-1 OpenBGPD形式での出力テスト）"