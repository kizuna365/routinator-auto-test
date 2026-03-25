#!/usr/bin/env bash

set -euo pipefail #コマンド失敗か未定義変数の使用でスクリプトを停止、パイプラインだと全体を停止

#local環境メモ(apt)
#ROUTINATOR_BIN=/usr/bin/routinator
#EXPECTED_ROUTINATOR_VERSION=0.15.1

# ===== 環境変数 =====

: "${ROUTINATOR_BIN:=routinator}" #バイナリの位置
# =====表示用ヘルパ=====

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }



info "Routinator テスト開始 (1.2 設定ファイル：デフォルト設定ファイルの生成確認)"

if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

TARGET_CONFIG="/etc/routinator/routinator.conf"


info "1) デフォルト設定ファイルの生成確認"

if "$ROUTINATOR_BIN" config >/dev/null 2>&1; then
        pass "内部デフォルト設定の動作チェック OK"
    else
        fail "内部エラー: Routinatorがデフォルト設定で起動できません"
    fi


pass "テスト完了（1.2 設定ファイル：デフォルト設定ファイルの生成確認）"