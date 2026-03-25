#!/usr/bin/env bash

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${RPKI_OUT_DIR:=./routinator-csv-out}"
: "${CSV_INPUT_FILE:=${RPKI_OUT_DIR}/vrps.csv}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（3.2 VRPデータの正確性：AS番号情報の正確性確認）"
if ! command -v python3 >/dev/null 2>&1; then fail "python3 が必要です"; fi
if [ ! -s "${CSV_INPUT_FILE}" ]; then fail "CSV成果物が見つかりません: ${CSV_INPUT_FILE}"; fi


# Cloudflare: 1.1.1.0/24 -> AS13335
# Google: 8.8.8.0/24 -> AS15169
TARGET_PREFIX_1="1.1.1.0/24"
TARGET_ASN_1="13335"

TARGET_PREFIX_2="8.8.8.0/24"
TARGET_ASN_2="15169"

info "検証対象1: ${TARGET_PREFIX_1} => AS${TARGET_ASN_1}"
info "検証対象2: ${TARGET_PREFIX_2} => AS${TARGET_ASN_2}"
info "検証内容: 指定されたPrefixに対し、正しいAS番号が紐付いているか"


set +e
python3 - "${CSV_INPUT_FILE}" "${TARGET_PREFIX_1}" "${TARGET_ASN_1}" "${TARGET_PREFIX_2}" "${TARGET_ASN_2}" <<'PY'
import sys, csv, re

csv_path = sys.argv[1]
# (Prefix, Expected_ASN) のタプルリストを作成
targets = [
    (sys.argv[2], int(sys.argv[3])),
    (sys.argv[4], int(sys.argv[5]))
]

def parse_asn_prefix(row):
    if not row or len(row) < 2: return None
    # ASN (カラム1)
    asn_s = (row[0] or "").strip()
    # Routinator等は "AS" を付けることがあるので除去して数値化
    m = re.match(r"^(?:AS)?(\d+)$", asn_s, re.IGNORECASE)
    if not m: return None
    asn = int(m.group(1))
    
    # Prefix (カラム2)
    prefix = (row[1] or "").strip().strip('"')
    return asn, prefix

found_count = 0
found_targets = set()

try:
    with open(csv_path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        for row in r:
            try: t = parse_asn_prefix(row)
            except: continue
            if not t: continue
            
            row_asn, row_prefix = t
            
            # ターゲットリストと照合
            for t_prefix, t_asn in targets:
                if t_prefix in found_targets: continue # 既に合格済みならスキップ

                if row_prefix == t_prefix:
                    # Prefixが一致した。AS番号も合っているか？
                    if row_asn == t_asn:
                        print(f"[OK] Match found: {row_prefix} is origin AS{row_asn}")
                        found_targets.add(t_prefix)
                        found_count += 1
                    else:
                        # Prefixは合ってるがASが違う場合（マルチホーム等の可能性もあるが、ここでは期待値不一致としてログ出す）
                        # print(f"[INFO] Prefix match but ASN mismatch: {row_prefix} (Got AS{row_asn}, Want AS{t_asn})")
                        pass

except Exception as e:
    print(f"[ERROR] File read error: {e}")
    sys.exit(1)

if found_count == len(targets):
    print("[SUCCESS] All target ASNs match.")
    sys.exit(0)
else:
    print(f"[FAIL] Only {found_count}/{len(targets)} pairs matched.")
    sys.exit(1)
PY
PYC=$?
set -e

if [ "${PYC}" -ne 0 ]; then
  fail "AS番号の正確性確認に失敗しました"
fi

pass "テスト完了（3.2 VRPデータの正確性：AS番号情報の正確性確認）"