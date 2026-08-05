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

info "テスト開始（3.2 VRPデータの正確性：プレフィックス情報の正確性確認）"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 が見つかりません"
fi



if [ ! -s "${CSV_INPUT_FILE}" ]; then
  fail "CSV成果物が見つかりません: ${CSV_INPUT_FILE}"
fi

# 2. 検証対象 (Prefixのみ指定)
# Cloudflare DNS と Google DNS
EXPECTED_PREFIX_1="1.1.1.0/24"
EXPECTED_PREFIX_2="8.8.8.0/24"

info "検証対象Prefix 1: ${EXPECTED_PREFIX_1}"
info "検証対象Prefix 2: ${EXPECTED_PREFIX_2}"
info "検証内容: Prefixが存在し、かつ 'Prefix長 <= MaxLength' の整合性が取れているか"

# 3. Pythonによる検証実行
set +e
python3 - "${CSV_INPUT_FILE}" "${EXPECTED_PREFIX_1}" "${EXPECTED_PREFIX_2}" <<'PY'
import sys, csv, re, ipaddress

csv_path = sys.argv[1]
target_prefixes = [sys.argv[2], sys.argv[3]]

# ロジックチェック: Prefix長 <= MaxLength <= アドレスビット数
def ok_prefix_and_maxlen(prefix, maxlen):
    try:
        net = ipaddress.ip_network(prefix, strict=False)
        plen = net.prefixlen
        bits = net.max_prefixlen
        return (0 <= plen <= bits) and (plen <= maxlen <= bits)
    except ValueError:
        return False

def parse_row(row):
    if not row or len(row) < 3: return None
    # Prefix (カラム2)
    prefix = (row[1] or "").strip().strip('"')
    # Max Length (カラム3)
    maxlen_s = (row[2] or "").strip()
    if not re.fullmatch(r"\d{1,3}", maxlen_s): return None
    return prefix, int(maxlen_s)

found_count = 0
found_prefixes = set()

try:
    with open(csv_path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        for row in r:
            try: t = parse_row(row)
            except: continue
            if not t: continue
            
            prefix, maxlen = t
            
            # ターゲットのPrefixか確認
            if prefix in target_prefixes:
                # 既に見つけたものはスキップ
                if prefix in found_prefixes: continue
                
                # 整合性チェック
                if ok_prefix_and_maxlen(prefix, maxlen):
                    print(f"[OK] Valid Prefix found: {prefix} (len) <= {maxlen} (maxlen)")
                    found_prefixes.add(prefix)
                    found_count += 1
                else:
                    print(f"[NG] Invalid range found: {prefix} maxlen={maxlen}")

except Exception as e:
    print(f"[ERROR] File read error: {e}")
    sys.exit(1)

if found_count == len(target_prefixes):
    print("[SUCCESS] All target prefixes are valid.")
    sys.exit(0)
else:
    print(f"[FAIL] Only {found_count}/{len(target_prefixes)} prefixes matched.")
    sys.exit(1)
PY
PYC=$?
set -e

if [ "${PYC}" -ne 0 ]; then
  fail "プレフィックス情報の整合性確認に失敗しました"
fi

pass "テスト完了（3.2 VRPデータの正確性：プレフィックス情報の正確性確認）"