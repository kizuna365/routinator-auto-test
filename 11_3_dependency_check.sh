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

info "Routinator テスト開始 (1.1 インストール確認：必要な依存関係の充足確認)"

# 1) 実行ファイルの存在確認
if command -v "$ROUTINATOR_BIN" >/dev/null 2>&1; then
    BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
    pass "実行ファイルを確認: ${BIN_PATH}"
else
    fail "実行ファイルが見つかりません: (ROUTINATOR_BIN='${ROUTINATOR_BIN}')"
fi

info "1) 共有ライブラリ（ldd が使える環境のみ）"
if command -v ldd >/dev/null 2>&1; then
  LDD_OUT="$(ldd "${BIN_PATH}" 2>&1 || true)"
  if printf '%s' "${LDD_OUT}" | grep -qi 'not a dynamic executable'; then
    info "静的リンクの可能性があるため、共有ライブラリの確認は不要です。"
  else
    MISSING_LIBS="$(printf '%s' "${LDD_OUT}" | awk '/not found/{print $1}' || true)"
    if [ -n "${MISSING_LIBS}" ]; then
      fail "必要な共有ライブラリが見つかりません。: ${MISSING_LIBS}"
    else
      pass "必要な依存関係の充足を確認しました（ldd）。"
    fi
  fi
else
  info "ldd が見つからないため、共有ライブラリの確認はスキップします。"
fi

info "2) rsync 実装の有無"
if command -v openrsync >/dev/null 2>&1; then
  pass "OpenRsync の存在を確認しました。: $(command -v openrsync)"
elif command -v rsync >/dev/null 2>&1; then
  pass "rsync の存在を確認しました。: $(command -v rsync)"
else
  warn "openrsync / rsync が見つかりません。rsync 経路での取得は実行できません（RRDP のみで動作）。必要に応じてインストールしてください。"
fi

pass "Routinator テスト完了(1.1 インストール確認：必要な依存関係の充足確認)"