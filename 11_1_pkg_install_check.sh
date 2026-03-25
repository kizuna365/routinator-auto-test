#!/usr/bin/env bash

set -euo pipefail #コマンド失敗か未定義変数の使用でスクリプトを停止、パイプラインだと全体を停止

#local環境メモ(apt)
#ROUTINATOR_BIN=/usr/bin/routinator
#EXPECTED_ROUTINATOR_VERSION=0.15.1


# ===== 環境変数 =====

: "${ROUTINATOR_BIN:=routinator}" #バイナリの位置

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "Routinator テスト開始 (1.1 インストール確認：パッケージのインストール成功確認)"

# 1) 実行ファイルの存在確認
if command -v "$ROUTINATOR_BIN" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
    pass "実行ファイルを確認: ${BIN_PATH}"
else
    fail "実行ファイルが見つかりません: (ROUTINATOR_BIN='${ROUTINATOR_BIN}')"
fi


info "1) パッケージのインストール状態（Debian 系のみ追加確認）"

if command -v dpkg-query >/dev/null 2>&1; then
  if dpkg-query -W -f='${Status}\n' routinator 2>/dev/null | grep -q 'install ok installed'; then
    pass "dpkg: routinator は install されています。"
  else
    info "dpkg には登録がありません（または dpkg 以外で導入）。実行ファイルが見つかったため以降のテストを続けます。"
  fi
else
  info "dpkg が無い環境（Debian 系以外）と判断しました。パッケージ状態チェックはスキップします。"
fi


pass "Routinator テスト完了(1.1 インストール確認：パッケージのインストール成功確認)"