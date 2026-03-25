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

# =====クリーンアップ設定=====
# スクリプト終了時(正常・異常問わず)に一時ファイルを削除する

TEMP_CONFIG=""
cleanup() {
    if [ -n "$TEMP_CONFIG" ] && [ -f "$TEMP_CONFIG" ]; then
        rm -f "$TEMP_CONFIG"
    fi
}
trap cleanup EXIT INT TERM

######

info "Routinator テスト開始 (1.2 設定ファイル：カスタム設定の読み込みテスト)"

if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

TARGET_CONFIG="/etc/routinator/routinator.conf"



info "1) カスタム設定の読み込みテスト"


TEMP_CONFIG=$(mktemp)
TEST_PORT="8323"


cat <<EOF > "$TEMP_CONFIG"
# --- Test Configuration ---
http-listen = ["127.0.0.1:8323"]
log-level = "warn"
disable-rrdp = true

# 必須項目: キャッシュディレクトリの場所
repository-dir = "/tmp/routinator-test-repo"

EOF

info "テスト用設定ファイルを作成しました: $TEMP_CONFIG"

if OUTPUT=$("$ROUTINATOR_BIN" -c "$TEMP_CONFIG" config 2>&1); then
    pass "カスタム設定の適用に成功しました"
else
    # 失敗した場合、Routinatorが吐いたエラーメッセージを表示する
    warn "コマンド出力: $OUTPUT"
    fail "カスタム設定の読み込みに失敗しました"
fi

if ! "$ROUTINATOR_BIN" config | grep -q "$TEST_PORT"; then
    pass "正常に元の設定に戻っています (ポート $TEST_PORT は無効化されました)"
else
    fail "エラー: カスタム設定の影響が残っています (ポート $TEST_PORT がまだ有効です)"
fi

pass "テスト完了（1.2 設定ファイル：カスタム設定の読み込みテスト）"