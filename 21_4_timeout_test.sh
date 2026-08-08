#!/usr/bin/env bash
# 21_4_timeout_test.sh
#
#
# 2. データ取得と検証機能 → 2.1 RPKIデータの取得
#   データ取得のタイムアウト設定テスト
#
set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"       # バイナリの位置
: "${RPKI_CACHE_DIR:=./routinator-timeout-cache}" # キャッシュディレクトリ
: "${RPKI_OUT_DIR:=./routinator-timeout-out}"     # 出力ディレクトリ
: "${RPKI_LOG_FILE:=./21_4_timeout_setting.log}"
: "${TIMEOUT_RRDP:=2}"
: "${TIMEOUT_RSYNC:=2}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1 RPKIデータの取得：データ取得のタイムアウト設定テスト）"


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

###

info "2) Routinator を タイムアウト指定付きで実行します..."

START_TS="$(date +%s)"

# --log-repository-issues : リポジトリ取得の問題ログを通常ログに出させる
#   0.15.0 以降、取得系のログはデフォルトでは server モードの HTTP ステータス
#   エンドポイントにしか出ない。vrps はワンショット実行なので参照手段が無く、
#   このオプションを付けない限りタイムアウトの記録がどこにも残らない。
#   グローバルオプションなので vrps より前に置く必要がある。
set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --rrdp-timeout "${TIMEOUT_RRDP}" \
  --rsync-timeout "${TIMEOUT_RSYNC}" \
  -vv \
  --log-repository-issues \
  vrps \
  --format json \
  --output "${RPKI_OUT_DIR}/vrps.json" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

END_TS="$(date +%s)"

ELAPSED="$(( END_TS - START_TS ))"

info "実行時間: ${ELAPSED} 秒"
if [ "${RC}" -eq 0 ]; then
    pass "プロセスは正常終了しました (Exit Code 0)"
else
    warn "プロセスが異常終了しました (Exit Code ${RC})"
fi

info "3) ログからタイムアウト確認"

# タイムアウトの文言は経路ごとに違う。
#   HTTP (RRDP) 経路 : [WARN] RRDP <notify-uri>: ...: operation timed out
#   rsync 経路       : [INFO] rsync <module>: rsync process reached time out
# rsync 側が [INFO] なのは LogBookWriter::warn() が Info レベルで出力するため。
# どちらも --log-repository-issues と -v 以上が揃っていないと出ない。
# --rrdp-timeout と --rsync-timeout の両方を検証するので、両経路とも必須とする。
MISSING=""
grep -qF 'operation timed out' "${RPKI_LOG_FILE}" \
    || MISSING="${MISSING} HTTP(RRDP)"
grep -qF 'rsync process reached time out' "${RPKI_LOG_FILE}" \
    || MISSING="${MISSING} rsync"

if [ -n "${MISSING}" ]; then
    # Docker 実行ではログファイルが残らないので、FAIL の材料はここに出す
    warn "タイムアウトが記録されていない経路:${MISSING}"
    warn "指定値: --rrdp-timeout=${TIMEOUT_RRDP} / --rsync-timeout=${TIMEOUT_RSYNC}"
    fail "タイムアウト設定が機能していることを確認できませんでした"
fi

pass "両経路でタイムアウトの発生を確認しました"
# head でパイプを閉じると grep が SIGPIPE で落ち、pipefail で誤 FAIL になる。
# grep -m 側で件数を絞る
grep -m 2 -F 'operation timed out' "${RPKI_LOG_FILE}" | awk '{print "   [LOG] " $0}'
grep -m 2 -F 'rsync process reached time out' "${RPKI_LOG_FILE}" | awk '{print "   [LOG] " $0}'



pass "テスト完了（2.1 RPKIデータの取得：データ取得のタイムアウト設定テスト）"