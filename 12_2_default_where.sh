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



info "Routinator テスト開始 (1.2 設定ファイル：設定ファイルの場所確認)"

if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

TARGET_CONFIG="/etc/routinator/routinator.conf"



info "1) 設定ファイルの場所確認"

if [ -f "$TARGET_CONFIG" ]; then
    pass "設定ファイルが存在します: $TARGET_CONFIG"
    if [ ! -r "$TARGET_CONFIG" ]; then
        warn "設定ファイルは存在しますが、現在のユーザーで読み込めません。"
    fi
else
    # 設定ファイルが見つからない場合の分岐
    warn "設定ファイルが見つかりません: $TARGET_CONFIG"
    
    # バイナリのパスに ".cargo" が含まれているかチェック
    if [[ "$BIN_PATH" == *".cargo"* ]]; then
        info "Cargoによるインストールを検出しました: $BIN_PATH"
        info "Cargo版はデフォルトでは設定ファイルを生成しません"
        pass "場所確認: 内部デフォルト設定を使用 (Cargo仕様)"
    else
        # Cargo以外（手動配置や不明なパス）の場合
        warn "設定ファイルが見当たらず、Cargo環境でもなさそうです"
        info "場所確認: 内部デフォルト設定を使用します"
    fi
fi



pass "テスト完了（1.2 設定ファイル：設定ファイルの場所確認）"