#!/usr/bin/env bash
#22_5_check_invalid_data_rejection.sh

<< COMMENT
解説

不正なデータの拒否テスト

1. rrdpとrsync排除（キャッシュのみ使用）でRoutinatorを実行し、拒否済みマニフェストの一覧と総VRP数を取得
2. stored/下の.mftファイルをCORRUPT_COUNT個破壊（バックアップ付き）
   破壊前の実行で既に拒否されていたものは候補から除外する
3. 再度キャッシュからRoutinatorを実行し、破壊した各マニフェストのURIが
   'no valid manifest <URI> found.' として新規に出現したかを突き合わせる

Routinatorが不正なデータを検出して拒否することを確認する

判定について:
  主判定は「破壊したURIが拒否ログに新規出現したか」の突き合わせ。
  VRP数の減少は参考値としてのみ表示し、判定には使わない。
  破壊したpointがVRPを1件も持たない場合、正しく拒否されてもVRP数は変化しないため。

  拒否ログは 0.15.0 以降デフォルトで通常ログに出力されない。
  参照するには --log-repository-issues が必要（グローバルオプションなので vrps より前に置く）。
  さらに LogBookWriter::warn() は Info レベルで出力するため -v 以上も必須。
COMMENT

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_OUT_DIR:=./routinator-validation-out}"
: "${RPKI_LOG_BEFORE:=./22_5_before.log}"
: "${RPKI_LOG_AFTER:=./22_5_after.log}"
: "${CORRUPT_COUNT:=5}"

STORED_DIR="${EXISTING_CACHE_DIR}/stored"
BEFORE_CSV="${RPKI_OUT_DIR}/before_corrupt.csv"
AFTER_CSV="${RPKI_OUT_DIR}/after_corrupt.csv"
# 破壊対象の一覧 (URI と パス)。破壊後ログとの突き合わせに使う中間ファイル
CORRUPT_LIST="${RPKI_OUT_DIR}/corrupted.tsv"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== バックアップファイルリスト =====
BACKUP_FILES=()

# ===== クリーンアップ関数 =====
cleanup() {
    if [ "${#BACKUP_FILES[@]}" -eq 0 ]; then
        return
    fi
    info "終了処理: バックアップからファイルを復元します..."
    local restored=0
    for backup in "${BACKUP_FILES[@]}"; do
        original="${backup%.bak}"
        if [ -f "${backup}" ]; then
            mv -f "${backup}" "${original}"
            restored=$((restored + 1))
        fi
    done
    info "復元完了: ${restored} 件"

    # 取り残しがあるとキャッシュが壊れたまま次のテストに持ち越されるので必ず確認する
    local leftover
    leftover="$(find "${STORED_DIR}" -name '*.mft.bak' -type f 2>/dev/null | wc -l)"
    if [ "${leftover}" -ne 0 ]; then
        warn "復元しきれていない .bak が ${leftover} 件あります。手動で確認してください:"
        warn "  find ${STORED_DIR} -name '*.mft.bak'"
    fi
}
trap cleanup EXIT INT TERM

# ===== stored パスから rsync URI を復元 =====
# store のレイアウト (routinator 0.15 系):
#   stored/rrdp/<notify-host>/<hash>/rsync/<uri-path>  … RRDP を広告する CA の point
#   stored/rsync/<uri-path>                            … rsync のみの point
# 先頭の固定要素を落とした残りが rsync URI のパス部になる
path_to_uri() {
    local rel="${1#"${STORED_DIR}"/}"
    case "${rel}" in
        rrdp/*)  printf 'rsync://%s\n' "$(printf '%s' "${rel}" | cut -d/ -f5-)" ;;
        rsync/*) printf 'rsync://%s\n' "$(printf '%s' "${rel}" | cut -d/ -f2-)" ;;
        *)       return 1 ;;
    esac
}

# ===== 拒否されたマニフェスト URI の集合を取り出す =====
extract_rejected_uris() {
    # grep は0件で exit 1 を返す。拒否が0件なのは正常な状態なので || true で受ける
    { grep -oE 'no valid manifest rsync://[^ ]+ found\.' "$1" || true; } \
        | sed -E 's/^no valid manifest (.*) found\.$/\1/' \
        | sort -u
}

# ===== キャッシュのみで vrps を実行 =====
run_vrps() {
    local csv="$1" log="$2"
    set +e
    "${ROUTINATOR_BIN}" \
        --repository-dir "${EXISTING_CACHE_DIR}" \
        --disable-rrdp \
        --disable-rsync \
        -vv \
        --log-repository-issues \
        vrps \
        --format csv \
        --output "${csv}" \
        > "${log}" 2>&1
    local rc=$?
    set -e
    return "${rc}"
}

# ===== メイン処理 =====

info "テスト開始（2.2 データ検証：不正なデータの拒否テスト）"

# Routinatorコマンド確認
if command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${ROUTINATOR_BIN}")"
  pass "Routinator の実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
fi

# キャッシュディレクトリ確認
if [ ! -d "${STORED_DIR}" ]; then
    fail "stored/ ディレクトリが見つかりません: ${STORED_DIR}"
fi

info "0) 前回の実行結果を掃除します"

mkdir -p "${RPKI_OUT_DIR}"


rm -f "${BEFORE_CSV}" "${AFTER_CSV}" "${CORRUPT_LIST}"
rm -f "${RPKI_LOG_BEFORE}" "${RPKI_LOG_AFTER}"

# 前回が異常終了して .bak が残っていると、破壊済みのキャッシュで測ることになる
ORPHANS="$(find "${STORED_DIR}" -name '*.mft.bak' -type f 2>/dev/null || true)"
if [ -n "${ORPHANS}" ]; then
    warn "前回の残骸 (.mft.bak) を検出しました。復元します:"
    while IFS= read -r bak; do
        [ -n "${bak}" ] || continue
        warn "  ${bak}"
        mv -f "${bak}" "${bak%.bak}"
    done <<< "${ORPHANS}"
fi

info "キャッシュディレクトリ: ${EXISTING_CACHE_DIR}"
info "出力ディレクトリ      : ${RPKI_OUT_DIR}"
info "破壊前ログ            : ${RPKI_LOG_BEFORE}"
info "破壊後ログ            : ${RPKI_LOG_AFTER}"

info "1) 破壊前: キャッシュからRoutinatorを実行"

if ! run_vrps "${BEFORE_CSV}" "${RPKI_LOG_BEFORE}"; then
    warn "コマンド出力 (末尾5行):"
    tail -n 5 "${RPKI_LOG_BEFORE}"
    fail "破壊前の Routinator 実行が失敗しました。ログを確認してください: ${RPKI_LOG_BEFORE}"
fi

if [ ! -f "${BEFORE_CSV}" ]; then
    fail "破壊前のVRPファイルが生成されませんでした"
fi

BEFORE_VRP_COUNT=$(tail -n +2 "${BEFORE_CSV}" | wc -l)
if [ "${BEFORE_VRP_COUNT}" -eq 0 ]; then
    fail "破壊前のVRP数が0です。キャッシュが空の可能性があります"
fi

# 破壊前から拒否されている point。候補から除外して「新規出現」を保証する
REJECTED_BEFORE="${RPKI_OUT_DIR}/rejected_before.txt"
extract_rejected_uris "${RPKI_LOG_BEFORE}" > "${REJECTED_BEFORE}"

info "2) 破壊対象の .mft を ${CORRUPT_COUNT} 個選定します"

# 除外で目減りするぶんを見込んで多めに引く
SAMPLE_SIZE=$(( CORRUPT_COUNT * 8 ))
CANDIDATES="$(find "${STORED_DIR}" -name '*.mft' -type f 2>/dev/null | shuf -n "${SAMPLE_SIZE}")"

if [ -z "${CANDIDATES}" ]; then
    fail ".mftファイルが見つかりません: ${STORED_DIR}"
fi

: > "${CORRUPT_LIST}"
SELECTED=0
while IFS= read -r mft_file; do
    [ -n "${mft_file}" ] || continue
    [ "${SELECTED}" -lt "${CORRUPT_COUNT}" ] || break

    if ! uri="$(path_to_uri "${mft_file}")"; then
        continue    # stored/ta/ など URI に対応しない配置
    fi

    # 既に拒否されている point を破壊しても「新規出現」にならず判定できない
    if grep -qxF "${uri}" "${REJECTED_BEFORE}"; then
        continue
    fi

    printf '%s\t%s\n' "${uri}" "${mft_file}" >> "${CORRUPT_LIST}"
    SELECTED=$((SELECTED + 1))
done <<< "${CANDIDATES}"

if [ "${SELECTED}" -eq 0 ]; then
    fail "破壊対象を選定できませんでした（有効な .mft が見つかりません）"
fi
if [ "${SELECTED}" -lt "${CORRUPT_COUNT}" ]; then
    warn "選定できたのは ${SELECTED} 件でした（要求: ${CORRUPT_COUNT} 件）"
fi
info "選定: ${SELECTED} 件（一覧: ${CORRUPT_LIST}）"

info "3) 選定した .mft を破壊します（バックアップ付き）"

while IFS=$'\t' read -r uri mft_file; do
    [ -n "${mft_file}" ] || continue

    backup_file="${mft_file}.bak"
    cp -p "${mft_file}" "${backup_file}"
    BACKUP_FILES+=("${backup_file}")

    # ファイルを破壊（先頭16バイトをランダムデータで上書き）
    # stored の point ファイルはヘッダから始まるため、これで point 全体が読めなくなる
    dd if=/dev/urandom of="${mft_file}" bs=16 count=1 conv=notrunc status=none
done < "${CORRUPT_LIST}"

info "${#BACKUP_FILES[@]}個の.mftファイルを破壊しました"

info "4) 破壊後: キャッシュからRoutinatorを再実行"

if ! run_vrps "${AFTER_CSV}" "${RPKI_LOG_AFTER}"; then
    warn "コマンド出力 (末尾5行):"
    tail -n 5 "${RPKI_LOG_AFTER}"
    fail "破壊後の Routinator 実行が失敗しました。ログを確認してください: ${RPKI_LOG_AFTER}"
fi

if [ ! -f "${AFTER_CSV}" ]; then
    fail "破壊後のVRPファイルが生成されませんでした"
fi

AFTER_VRP_COUNT=$(tail -n +2 "${AFTER_CSV}" | wc -l)

info "5) 破壊したマニフェストが拒否されたかを突き合わせます"

MATCHED=0
UNMATCHED=""
while IFS=$'\t' read -r uri mft_file; do
    [ -n "${uri}" ] || continue

    if grep -qF "no valid manifest ${uri} found." "${RPKI_LOG_AFTER}"; then
        MATCHED=$((MATCHED + 1))
    else
        UNMATCHED="${UNMATCHED}${uri}"$'\n'
    fi
done < "${CORRUPT_LIST}"

if [ -n "${UNMATCHED}" ]; then
    # Docker 実行ではログファイルが残らないので、FAIL の材料はここに出す
    warn "破壊したにもかかわらず拒否ログに出なかったマニフェスト:"
    printf '%s' "${UNMATCHED}" | awk '{print "   " $0}'
    fail "不正データの拒否を確認できませんでした（拒否 ${MATCHED} / ${SELECTED} 件）"
fi

pass "破壊した ${MATCHED} 件すべてが 'no valid manifest' として拒否されました"
awk -F'\t' 'NR<=3 {print "   [拒否] " $1}' "${CORRUPT_LIST}"
# 参考値。破壊した point が VRP を持たない場合は減らないので判定には使わない
info "参考: VRP数 ${BEFORE_VRP_COUNT} → ${AFTER_VRP_COUNT} (判定には使わない)"

pass "テスト完了（2.2 データ検証：不正なデータの拒否テスト）"
