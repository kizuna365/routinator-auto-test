#!/usr/bin/env bash
#22_5_check_invalid_data_rejection.sh

<< COMMENT
解説

不正なデータの拒否テスト

1. rrdpとrsync排除（キャッシュのみ使用）でRoutinatorを実行し、総VRP数を取得
2. stored/下の.mftファイルを5個破壊（バックアップ付き）
3. 再度キャッシュからRoutinatorを実行してVRP数の変化を確認

Routinatorが不正なデータを検出して拒否することを確認する

COMMENT

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_OUT_DIR:=./routinator-validation-out}"
: "${CORRUPT_COUNT:=5}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== バックアップファイルリスト =====
BACKUP_FILES=()

# ===== クリーンアップ関数 =====
cleanup() {
    info "終了処理: バックアップからファイルを復元します..."
    for backup in "${BACKUP_FILES[@]}"; do
        original="${backup%.bak}"
        if [ -f "${backup}" ]; then
            mv "${backup}" "${original}"
        fi
    done
    info "復元完了"
}
trap cleanup EXIT INT TERM

# ===== メイン処理 =====


info "テスト開始（2.2 データ検証：不正なデータの拒否テスト）"

# キャッシュディレクトリ確認


STORED_DIR="${EXISTING_CACHE_DIR}/stored"
if [ ! -d "${STORED_DIR}" ]; then
    fail "stored/ ディレクトリが見つかりません: ${STORED_DIR}"
fi

mkdir -p "${RPKI_OUT_DIR}"

# Routinatorコマンド確認
if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

info "1) 破壊前: キャッシュからRoutinatorを実行してVRP数を取得"

BEFORE_CSV="${RPKI_OUT_DIR}/before_corrupt.csv"

set +e
"${ROUTINATOR_BIN}" \
    --repository-dir "${EXISTING_CACHE_DIR}" \
    --disable-rrdp \
    --disable-rsync \
    vrps \
    --format csv \
    --output "${BEFORE_CSV}" 2>/dev/null
set -e

if [ ! -f "${BEFORE_CSV}" ]; then
    fail "破壊前のVRPファイルが生成されませんでした"
fi

BEFORE_VRP_COUNT=$(tail -n +2 "${BEFORE_CSV}" | wc -l)
info "破壊前VRP数: ${BEFORE_VRP_COUNT}"

if [ "${BEFORE_VRP_COUNT}" -eq 0 ]; then
    fail "破壊前のVRP数が0です。キャッシュが空の可能性があります"
fi

info "破壊前VRP数取得完了: ${BEFORE_VRP_COUNT} VRPs"

info "2) stored/下の.mftファイルを${CORRUPT_COUNT}個破壊（バックアップ付き）"

# ランダムに.mftファイルを選択
CORRUPT_TARGETS=$(find "${STORED_DIR}" -name "*.mft" -type f 2>/dev/null | shuf -n "${CORRUPT_COUNT}")

if [ -z "${CORRUPT_TARGETS}" ]; then
    fail ".mftファイルが見つかりません"
fi

ACTUAL_COUNT=0
while IFS= read -r mft_file; do
    # バックアップ作成
    backup_file="${mft_file}.bak"
    cp "${mft_file}" "${backup_file}"
    BACKUP_FILES+=("${backup_file}")
    
    # ファイルを破壊（先頭16バイトをランダムデータで上書き）
    dd if=/dev/urandom of="${mft_file}" bs=16 count=1 conv=notrunc 2>/dev/null
    
    ACTUAL_COUNT=$((ACTUAL_COUNT + 1))
done <<< "${CORRUPT_TARGETS}"

info "${ACTUAL_COUNT}個の.mftファイルを破壊しました"

info "3) 破壊後: キャッシュからRoutinatorを再実行"

AFTER_CSV="${RPKI_OUT_DIR}/after_corrupt.csv"

set +e
"${ROUTINATOR_BIN}" \
    --repository-dir "${EXISTING_CACHE_DIR}" \
    --disable-rrdp \
    --disable-rsync \
    vrps \
    --format csv \
    --output "${AFTER_CSV}" 2>/dev/null
set -e

if [ ! -f "${AFTER_CSV}" ]; then
    warn "破壊後のVRPファイルが生成されませんでした"
    AFTER_VRP_COUNT=0
else
    AFTER_VRP_COUNT=$(tail -n +2 "${AFTER_CSV}" | wc -l)
fi

info "破壊後VRP数: ${AFTER_VRP_COUNT}"

info "4) VRP数の変化を分析"

VRP_DIFF=$((BEFORE_VRP_COUNT - AFTER_VRP_COUNT))
info "   変化量: -${VRP_DIFF} VRPs"

if [ "${VRP_DIFF}" -gt 0 ]; then
    pass "不正なデータが拒否されました"
    info "   破壊前: ${BEFORE_VRP_COUNT} VRPs"
    info "   破壊後: ${AFTER_VRP_COUNT} VRPs"
    info "   減少量: ${VRP_DIFF} VRPs (${CORRUPT_COUNT}ファイル破壊)"
    
else
    fail "VRP数が減少していません - 不正データが拒否されていない可能性があります"
fi


pass "テスト完了（2.2 データ検証：不正なデータの拒否テスト）"
