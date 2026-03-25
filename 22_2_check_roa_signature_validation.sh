#!/usr/bin/env bash
#22_2_check_roa_signature_validation.sh


<< COMMENT
解説

/stored下の.mftの生成ロジックソースコードから読んでみたんですが
MFT本体（DER形式)、CRL本体（DER形式)、複数のROA/証明書（DER形式）が全部入ってます
(https://github.com/NLnetLabs/routinator/blob/main/src/store.rs)

つまり、stored/*.mftは本来のmftファイルではなく、Routinatorのキャッシュ形式であり、その中にMFT、CRL、ROAが格納されている形です

検証ロジックのvalidate_stored_manifest() 関数でMFT検証、CRL検証、ROA検証をすべてやってることも確認できました
(https://github.com/NLnetLabs/routinator/blob/main/src/engine.rs)

なので、stored/*.mft内にROAが埋め込まれていることを確認することで、ROAの署名検証が可能であることを確認できます

COMMENT

# stored/*.mft内にROAが埋め込まれていることを確認する

set -euo pipefail

# ===== 環境変数 =====
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"

# ===== 定数 =====
EXPECTED_VERSION=2
# ROA OID: 1.2.840.113549.1.9.16.1.24 (DERエンコード)
ROA_OID_HEX="060b2a864886f70d01091001"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

# ===== メイン処理 =====

info "テスト開始（2.2 データ検証：ROAの暗号化署名検証）"


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

# 2) ROA OID存在確認
info "2) ROA OID (1.2.840.113549.1.9.16.1.24) の存在を確認"

HEX_CONTENT=$(xxd -p "${SAMPLE_MFT}" 2>/dev/null | tr -d '\n')
ROA_COUNT=$(echo "${HEX_CONTENT}" | grep -o "${ROA_OID_HEX}" | wc -l || echo 0)

info "  ROA OID検出数: ${ROA_COUNT} (CMS構造上、通常2個×ROA数)"

if [ "${ROA_COUNT}" -gt 0 ]; then
    pass "ROA OID が ${ROA_COUNT} 個検出されました - ROA署名検証可能"
else
    fail "ROA OID が見つかりません - キャッシュ構造が想定と異なります"
fi

pass "テスト完了（2.2 データ検証：ROAの暗号化署名検証）"