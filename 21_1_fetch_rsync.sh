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
# --log-repository-issues : リポジトリ取得の問題ログを通常ログに出させる
#   0.15.0 以降、取得系のログはデフォルトでは server モードの HTTP ステータス
#   エンドポイントにしか出ない。vrps はワンショット実行なので参照手段が無く、
#   このオプションを付けない限りモジュール単位の取得記録がどこにも残らない。
#   グローバルオプションなので vrps より前に置く必要がある。
# vrps : VRPリストを出力するコマンド (同期処理も含む)
# --format json : 出力形式
# --output ... : 結果の保存先

info "3) Routinator を rsync 強制モード (--disable-rrdp) で実行します"

set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --disable-rrdp \
  -vv \
  --log-repository-issues \
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

info "4) rsync によるモジュール取得が成立したか確認"



# --log-repository-issues 付きで出るモジュール単位の行:
#   [DEBUG] rsync <module>: running command Command { ... }   … rsync を起動した
#   [WARN]  rsync <module>: rsync error: ...                  … rsync が失敗した
#   [ERROR] rsync <module>: ...                               … 取得を諦めた
# rsync は成功時に何も出さない (成功完了ログが upstream に実装されていない)。
info "成功したモジュール = rsync を起動したモジュール - 失敗したモジュール で判定します"

# grep は0件マッチで exit 1 を返し pipefail に引っかかるので sed で抜く
modules_started() {
  sed -nE 's/^\[[A-Z]+\] rsync (rsync:\/\/[^ ]+): running command.*/\1/p' "${RPKI_LOG_FILE}" | sort -u
}
modules_failed() {
  sed -nE 's/^\[(WARN|ERROR)\] rsync (rsync:\/\/[^ ]+): .*/\2/p' "${RPKI_LOG_FILE}" | sort -u
}

if [ -z "$(comm -23 <(modules_started) <(modules_failed))" ]; then
  # Docker 実行ではログファイルが残らないので、FAIL の材料はここに出す
  warn "起動したモジュール (先頭5件):"
  modules_started | awk 'NR<=5 {print "   " $0}'
  warn "失敗したモジュール (先頭5件):"
  modules_failed | awk 'NR<=5 {print "   " $0}'
  fail "rsync による取得に成功したモジュールがありません"
fi
pass "rsync による取得に成功したモジュールを確認しました"

info "5) 取得したデータが検証を通ったか確認"

VRP_COUNT="$(grep -c '"prefix"' "${RPKI_OUT_DIR}/vrps.json" || true)"
if [ "${VRP_COUNT}" -eq 0 ]; then
  fail "VRPが1件も出力されていません。rsync で取得したデータが検証を通っていません"
fi
pass "rsync で取得したデータから VRP が出力されました (${VRP_COUNT}件)"

pass "テスト完了（2.1 RPKIデータの取得：rsyncプロトコルによる取得テスト）"