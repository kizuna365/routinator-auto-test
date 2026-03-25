#!/usr/bin/env bash
#22_3_check_crl_validation.sh


<< COMMENT
解説

/stored下の.mftの生成ロジックソースコードから読んでみたんですが
MFT本体（DER形式)、CRL本体（DER形式)、複数のROA/証明書（DER形式）が全部入ってます
(https://github.com/NLnetLabs/routinator/blob/main/src/store.rs)

つまり、stored/*.mftは本来のmftファイルではなく、Routinatorのキャッシュ形式であり、その中にMFT、CRL、ROAが格納されている形です

検証ロジックのvalidate_stored_manifest() 関数でMFT検証、CRL検証、ROA検証をすべてやってることも確認できました
(https://github.com/NLnetLabs/routinator/blob/main/src/engine.rs)

なので、stored/*.mft内にCRLが埋め込まれていることを確認することで、CRLの検証が可能であることを確認できます

ただ、CRLにはcontent-type OIDがないため、CRL Number拡張 (2.5.29.20) で検知します
RPKIのCRLには必ずCRL Number拡張が含まれるため、これでCRLの存在を確認できます

COMMENT


# stored/*.mft内にCRLが埋め込まれていることを確認する



set -euo pipefail

# ===== 環境変数 =====
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"

# ===== 定数 =====
EXPECTED_VERSION=2
# CRL Number拡張 OID: 2.5.29.20 (DERエンコード)
CRL_NUMBER_OID_HEX="0603551d14"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== メイン処理 =====

info "テスト開始（2.2 データ検証：CRLの検証）"


# キャッシュディレクトリ確認


STORED_DIR="${EXISTING_CACHE_DIR}/stored"
if [ ! -d "${STORED_DIR}" ]; then
    fail "stored/ ディレクトリが見つかりません: ${STORED_DIR}"
fi

# サンプルファイル取得（ランダムに1つ選択）
SAMPLE_MFT=$(find "${STORED_DIR}" -name "*.mft" -type f 2>/dev/null | shuf -n 1)
if [ -z "${SAMPLE_MFT}" ]; then
    fail "stored/ 内に .mft ファイルが見つかりません"
fi

info "解析対象: ${SAMPLE_MFT}"

# 1) ヘッダバージョンチェック
info "1) StoredPointHeader バージョンを確認"

VERSION_BYTE=$(od -An -tu1 -N1 "${SAMPLE_MFT}" 2>/dev/null | tr -d ' ')
info "  検出バージョン: ${VERSION_BYTE}"

if [ "${VERSION_BYTE}" = "${EXPECTED_VERSION}" ]; then
    pass "StoredPointHeader VERSION = ${VERSION_BYTE} (期待値: ${EXPECTED_VERSION})"
else
    warn "StoredPointHeader VERSION変更検知!"
    warn "期待値: ${EXPECTED_VERSION}"
    warn "実際値: ${VERSION_BYTE}"
    warn "Routinatorのキャッシュ形式が変更された可能性があります"
fi

# 2) CRL Number OID存在確認
info "2) CRL Number OID (2.5.29.20) の存在を確認"

HEX_CONTENT=$(xxd -p "${SAMPLE_MFT}" 2>/dev/null | tr -d '\n')
CRL_COUNT=$(echo "${HEX_CONTENT}" | grep -o "${CRL_NUMBER_OID_HEX}" | wc -l || echo 0)

# stored/*.mft構造（Routinator store.rs より）:
#   StoredPointHeader + StoredManifest + StoredObjects...
#
# CRL Number OIDが2回出現する理由（バイナリ解析で確認済み）:
#   1. StoredManifest.crl フィールド
#      - 検証処理で即座にアクセスできるよう格納
#      - store.rs: "As it needs to be available for validation, we might as well store it together with the manifest"
#   2. StoredObject (CRL) として格納
#      - MFTが参照するすべてのオブジェクト（ROA, CRL等）のリストに含まれる
#
# → 同一のCRLデータが意図的に2箇所に格納される設計（SHA256ハッシュ一致確認済み）
info "  CRL Number OID検出数: ${CRL_COUNT} (StoredManifest.crl + StoredObject.crl で通常2個)"

if [ "${CRL_COUNT}" -gt 0 ]; then
    pass "CRL Number OID が ${CRL_COUNT} 個検出されました - CRL検証可能"
else
    fail "CRL Number OID が見つかりません - キャッシュ構造が想定と異なります"
fi


pass "テスト完了（2.2 データ検証：CRLの検証）"

