#!/usr/bin/env bash
#22_1_check_cert_chain_validation.sh

#手動 $ bash 22_1_check_cert_chain_validation.sh
#自動入力 $ SUDO_PASSWORD="pass" bash 22_1_check_cert_chain_validation.sh

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"       # バイナリの位置
: "${RPKI_CACHE_DIR:=./routinator-rsync-chain-cache}" # キャッシュディレクトリ
: "${RPKI_OUT_DIR:=./routinator-rsync-chain-out}"     # 出力ディレクトリ
: "${RPKI_LOG_FILE:=./22_1_check_cert_chain_validation.log}"
: "${SUDO_PASSWORD:=}"

TARGET_HOSTS=(
    "rpki.ripe.net"
    "rpki.apnic.net"
    "rpki.arin.net"
    "rpki.afrinic.net"
    "repository.lacnic.net"
    "rrdp.lacnic.net"
)

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== sudo ラッパー関数 =====

do_sudo() {
if [ -n "${SUDO_PASSWORD}" ]; then
        echo "${SUDO_PASSWORD}" | sudo -S -v >/dev/null 2>&1
        pass "sudoパスワードを自動入力し、認証を更新しました"
    else
        sudo -v
    fi
}

# ===== クリーンアップ関数 =====
cleanup() {
  if [ -f /etc/hosts.bak ]; then
    info "終了処理: /etc/hosts を復元します..."
    sudo cp /etc/hosts.bak /etc/hosts && sudo rm -f /etc/hosts.bak
    info "/etc/hosts を元に戻しました"
  fi
}
trap cleanup EXIT INT TERM

# ===== メイン処理 =====

info "テスト開始（2.2 データ検証：証明書チェーン検証）"

do_sudo

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

info "3) /etc/hosts を書き換えて全RIRのTAL検証を失敗させます"

# バックアップ作成
sudo cp /etc/hosts /etc/hosts.bak

# 全RIRをループして 127.0.0.1 に向ける
for host in "${TARGET_HOSTS[@]}"; do
    echo "127.0.0.1 ${host}" | sudo tee -a /etc/hosts > /dev/null
done

pass "以下のホストを 127.0.0.1 に設定しました: ${TARGET_HOSTS[*]}"

info "4) Routinator を rsync 強制モード (--disable-rrdp) で実行します"

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

info "5) ログ内に TAL検証失敗が記録されているか確認"

if grep -q 'No valid trust anchor for' "${RPKI_LOG_FILE}"; then
  pass "ログ内で TAL検証失敗の記録を確認しました"
  # 具体的な行を抽出して表示（確認用）
  # head でパイプを閉じると grep が SIGPIPE で落ち、pipefail で誤 FAIL になる。
  # 件数は grep -m 側で絞る
  grep -m 5 'No valid trust anchor for' "${RPKI_LOG_FILE}" | awk '{print "   [LOG] " $0}'
else
  # rsync:// がログにない場合の警告
  fail "ログ内でTAL検証失敗の記録が確認できません。"
fi

pass "テスト完了（2.2 データ検証：証明書チェーン検証）"