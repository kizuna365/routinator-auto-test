#!/usr/bin/env bash

set -euo pipefail 



# ===== 環境変数 =====

: "${ROUTINATOR_BIN:=routinator}" # バイナリの位置
: "${RPKI_CACHE_DIR:=./routinator-rsync-cache}" # キャッシュディレクトリ
: "${RPKI_OUT_DIR:=./routinator-rsync-out}"     # 出力ディレクトリ
: "${RPKI_LOG_FILE:=./21_1_fetch_rsync.log}"

# ===== 表示用ヘルパ =====

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1 RPKIデータの取得：rsyncプロトコルによる取得テスト）"



if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

info "1) rsync 実装の確認"
if command -v openrsync >/dev/null 2>&1; then
  RSYNC_BIN="$(command -v openrsync)"
  pass "Openrsync の存在を確認しました: ${RSYNC_BIN}"
elif command -v rsync >/dev/null 2>&1; then
  RSYNC_BIN="$(command -v rsync)"
  pass "rsync の存在を確認しました: ${RSYNC_BIN}"
else
  warn "openrsync / rsync が見つかりません。Routinator は rsync 切り替えに失敗する可能性があります。"
fi

info "2) ディレクトリの準備"
mkdir -p "${RPKI_OUT_DIR}"

if [ -d "${RPKI_CACHE_DIR}" ]; then
    info "既存のキャッシュをクリアします: ${RPKI_CACHE_DIR}"
    rm -rf "${RPKI_CACHE_DIR}"
fi
rm -f "${RPKI_LOG_FILE}"

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ      : ${RPKI_OUT_DIR}"
info "ログファイル          : ${RPKI_LOG_FILE}"

# 4) rsync のみで取得（--disable-rrdp 指定）して検証

# オプション解説:
# --base-dir / --repository-dir : キャッシュの保存先
# --disable-rrdp : RRDP (HTTPS) を無効化し、rsync を強制する
# vv : ログにプロトコル詳細を出させるため debug に設定
# vrps : VRPリストを出力するコマンド (同期処理も含む)
# --format json : 出力形式
# --output ... : 結果の保存先

info "3) Routinator を rsync 強制モード (--disable-rrdp) で実行します"

set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --disable-rrdp \
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

info "4) ログ内に rsync アクセスが記録されているか確認"

if grep -q 'rsync://' "${RPKI_LOG_FILE}"; then
  pass "ログ内で rsync プロトコルによる取得記録を確認しました"
  # 具体的な行を抽出して表示（確認用）
  grep 'rsync://' "${RPKI_LOG_FILE}" | head -n 3 | awk '{print "   [LOG] " $0}'
else
  # rsync:// がログにない場合の警告
  fail "ログ内に 'rsync://' の文字列が見当たりません。"
fi

pass "テスト完了（2.1 RPKIデータの取得：rsyncプロトコルによる取得テスト）"