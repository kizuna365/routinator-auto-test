#!/usr/bin/env bash
# 21_2_fetch_rrdp.sh
#
# 2. データ取得と検証機能 → 2.1 RPKIデータの取得
#   RRDPによるデータ取得テスト
#


set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"       # バイナリの位置
: "${RPKI_CACHE_DIR:=./routinator-rrdp-cache}" # キャッシュディレクトリ
: "${RPKI_OUT_DIR:=./routinator-rrdp-out}"     # 出力ディレクトリ
: "${RPKI_LOG_FILE:=./21_2_fetch_rrdp.log}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1 RPKIデータの取得：RRDPによる取得テスト）"


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

# 2) RRDP のみで取得（--disable-rsync 指定）して検証

info "2) Routinator を RRDP 強制モード (--disable-rsync) で実行します..."
set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --disable-rsync \
  --rrdp-connect-timeout 1200 \
  --rrdp-read-timeout 1200 \
  --rrdp-timeout 1200 \
  -vv \
  vrps \
  --format json \
  --output "${RPKI_OUT_DIR}/vrps.json" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  warn "コマンド出力 (末尾5行):"
  tail -n 5 "${RPKI_LOG_FILE}"
  fail "Routinator の実行が失敗しました（終了コード=${RC}）。ログを確認してください: ${RPKI_LOG_FILE}"
fi
pass "Routinator の実行が正常に完了しました"

info "3) ログ内に RRDP アクセスが記録されているか確認"

# "RRDP" または "https://" を検索
if grep -q -E 'RRDP|https://' "${RPKI_LOG_FILE}"; then
  pass "ログ内で RRDP/HTTPS プロトコルによる取得記録を確認しました"
  
  # 確認用にログの一部を表示 (URLが見える行などを抽出)
  # "Processing https://..." や "RRDP:" などを抽出
  grep -E 'rrdp' "${RPKI_LOG_FILE}" | head -n 3 | awk '{print "   [LOG] " $0}'
else
  warn "ログ内に RRDP 通信を示す明確な文字列が見当たりません。"
  warn "詳細確認のためログを見てください: ${RPKI_LOG_FILE}"
fi

pass "テスト完了（2.1 RPKIデータの取得：RRDPによる取得テスト）"
