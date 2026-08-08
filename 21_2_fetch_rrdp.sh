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

# --log-repository-issues : リポジトリ取得の問題ログを通常ログに出させる
#   0.15.0 以降、取得系のログはデフォルトでは server モードの HTTP ステータス
#   エンドポイントにしか出ない。vrps はワンショット実行なので参照手段が無く、
#   このオプションを付けない限り RRDP の更新記録がどこにも残らない。
#   グローバルオプションなので vrps より前に置く必要がある。
set +e
"${ROUTINATOR_BIN}" \
  --repository-dir "${RPKI_CACHE_DIR}" \
  --disable-rsync \
  --rrdp-connect-timeout 1200 \
  --rrdp-read-timeout 1200 \
  --rrdp-timeout 1200 \
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

info "3) RRDP による更新が完了したリポジトリを確認"



# --log-repository-issues 付きで出るリポジトリ単位の行:
#   [DEBUG] RRDP <notify-uri>: snapshot update completed.   … snapshot から更新した
#   [DEBUG] RRDP <notify-uri>: Delta update completed.      … delta で更新した
#   [WARN]  RRDP <notify-uri>: ...                          … 更新に失敗した
# キャッシュを消してから実行するので通常は snapshot 側だが、
# 実行中に delta へ切り替わる場合もあるため両方を拾う。

if grep -qE ': (snapshot|Delta) update completed\.' "${RPKI_LOG_FILE}"; then
  pass "RRDP による更新完了を確認しました"
  grep -m 3 -E ': (snapshot|Delta) update completed\.' "${RPKI_LOG_FILE}" \
    | awk '{print "   [LOG] " $0}'
else
  # Docker 実行ではログファイルが残らないので、FAIL の材料はここに出す
  warn "'snapshot update completed.' / 'Delta update completed.' がいずれも出ていません"
  warn "RRDP の失敗行 (先頭5件):"
  sed -nE 's/^\[(WARN|ERROR)\] RRDP (https:\/\/.*)/   \2/p' "${RPKI_LOG_FILE}" | awk 'NR<=5'
  fail "RRDP による更新が完了したリポジトリがありません"
fi

info "4) 取得したデータが検証を通ったか確認"

VRP_COUNT="$(grep -c '"prefix"' "${RPKI_OUT_DIR}/vrps.json" || true)"
if [ "${VRP_COUNT}" -eq 0 ]; then
  fail "VRPが1件も出力されていません。RRDP で取得したデータが検証を通っていません"
fi
pass "RRDP で取得したデータから VRP が出力されました (${VRP_COUNT}件)"

pass "テスト完了（2.1 RPKIデータの取得：RRDPによる取得テスト）"
