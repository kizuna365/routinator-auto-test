#!/usr/bin/env bash

set -euo pipefail #コマンド失敗か未定義変数の使用でスクリプトを停止、パイプラインだと全体を停止

#local環境メモ(apt)
#ROUTINATOR_BIN=/usr/bin/routinator
#EXPECTED_ROUTINATOR_VERSION=0.15.1


# ===== 環境変数 =====

: "${ROUTINATOR_BIN:=routinator}" #バイナリの位置
: "${EXPECTED_ROUTINATOR_VERSION:=}" #検証バージョン指定、未指定なら存在のみ確認

# =====表示用ヘルパ=====

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "Routinator テスト開始 (1.1 インストール確認：バージョン情報の確認)"

# 1) 実行ファイルの存在確認
if command -v "$ROUTINATOR_BIN" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
    pass "実行ファイルを確認: ${BIN_PATH}"
else
    fail "実行ファイルが見つかりません: (ROUTINATOR_BIN='${ROUTINATOR_BIN}')"
fi

info "1) バージョン情報の確認（-V）"
set +e #エラーでも停止しないように一時変更
VERSION_OUT="$("${ROUTINATOR_BIN}" -V 2>&1)"
RC=$? #直前のコマンドの終了コードを取得
set -e

if [ $RC -ne 0 ]; then
  fail "routinator -V が0以外のコードで終了しました（rc=${RC}）。出力: ${VERSION_OUT}"
fi
if [ -z "${VERSION_OUT}" ]; then
  fail "routinator -V の出力が空です。"
fi

if ! printf '%s' "${VERSION_OUT}" | grep -Eiq '^routinator[[:space:]]+[0-9]'; then
  fail "routinator -V の出力形式が想定外です。: ${VERSION_OUT}"
fi

pass "バージョンを取得しました。: ${VERSION_OUT}"

info "2) 指定バージョンの確認（指定がある場合のみ）"
if [ -n "${EXPECTED_ROUTINATOR_VERSION}" ]; then
  if printf '%s' "${VERSION_OUT}" | grep -Fq "${EXPECTED_ROUTINATOR_VERSION}"; then
    pass "期待されるバージョンと一致しました。: ${EXPECTED_ROUTINATOR_VERSION}"
  else
    fail "期待されるバージョンと一致しません。期待バージョン=${EXPECTED_ROUTINATOR_VERSION}, 導入されているバージョン='${VERSION_OUT}'"
  fi
else
  info "EXPECTED_ROUTINATOR_VERSION の指定がないため、バージョンの取得のみを実施しました。"
fi

pass "Routinator テスト完了(1.1 インストール確認：バージョン情報の確認)"
