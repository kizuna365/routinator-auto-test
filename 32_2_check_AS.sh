#!/usr/bin/env bash

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_LOG_FILE:=./32_2_check_AS.log}"
: "${VRP_FILE:=./32_2_vrps.csv}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }

info "テスト開始（3.2 VRPデータの正確性：AS番号情報の正確性確認）"
info "検証内容: 出力の各行の AS 番号が、出どころの ROA に書かれた AS 番号と一致するか"

command -v "${ROUTINATOR_BIN}" >/dev/null 2>&1 || fail "Routinator の実行ファイルが見つかりません（ROUTINATOR_BIN='${ROUTINATOR_BIN}'）"
command -v python3 >/dev/null 2>&1 || fail "python3 が見つかりません"
# 正解は rsync で取った生の ROA ファイルから読む。Routinator 独自の形式 (stored/) は版で変わりうるので読まない
[ -d "${EXISTING_CACHE_DIR}/rsync" ] || fail "キャッシュが見つかりません: ${EXISTING_CACHE_DIR}/rsync"

info "1) キャッシュだけで VRP を出力します（csvext。行ごとに出どころの ROA の URI が付く）"
set +e
"${ROUTINATOR_BIN}" \
    --repository-dir "${EXISTING_CACHE_DIR}" \
    --disable-rrdp \
    --disable-rsync \
    vrps \
    --format csvext \
    --output "${VRP_FILE}" \
    > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e
if [ "${RC}" -ne 0 ]; then
    sed 's/^/   /' "${RPKI_LOG_FILE}"
    fail "Routinator の実行が失敗しました（RC=${RC}）"
fi

info "2) 出力に出てきた ROA をキャッシュから読み、AS 番号を照合します"
out=$(python3 - "${VRP_FILE}" "${EXISTING_CACHE_DIR}/rsync" 2>&1 <<'PY' || true
import sys, csv, ipaddress

vrp_file, rsync_dir = sys.argv[1], sys.argv[2]
ROA_OID = bytes.fromhex("2a864886f70d0109100118")  # 1.2.840.113549.1.9.16.1.24


def tlv(b, i):
    tag = b[i]
    n = b[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7f
        n = int.from_bytes(b[i:i + k], "big")
        i += k
    return tag, b[i:i + n], i + n


def children(b):
    i, out = 0, []
    while i < len(b):
        t, v, i = tlv(b, i)
        out.append((t, v))
    return out


# RFC 6482: ContentInfo > SignedData > EncapsulatedContentInfo > RouteOriginAttestation
def read_roa(path):
    with open(path, "rb") as f:
        der = f.read()
    signed_data = children(children(tlv(der, 0)[1])[1][1])[0][1]
    eci = [v for t, v in children(signed_data) if t == 0x30][0]
    oid, econtent = children(eci)
    if oid[1] != ROA_OID:
        raise ValueError("eContentType が ROA ではありません")
    roa = children(children(children(econtent[1])[0][1])[0][1])
    if roa[0][0] == 0xa0:
        roa = roa[1:]
    asn = int.from_bytes(roa[0][1], "big")
    vrps = set()
    for _, family in children(roa[1][1]):
        afi, addresses = children(family)
        bits = 32 if afi[1][:2] == b"\x00\x01" else 128
        for _, entry in children(addresses[1]):
            parts = children(entry)
            bitstr = parts[0][1]
            plen = (len(bitstr) - 1) * 8 - bitstr[0]
            addr = int.from_bytes(bitstr[1:].ljust(bits // 8, b"\0"), "big")
            prefix = str(ipaddress.ip_network((addr, plen)))
            maxlen = int.from_bytes(parts[1][1], "big") if len(parts) > 1 else plen
            vrps.add((prefix, maxlen))
    return asn, vrps


try:
    rows = {}
    with open(vrp_file, newline="") as f:
        reader = csv.reader(f)
        header = next(reader, [])
        if header[:4] != ["URI", "ASN", "IP Prefix", "Max Length"]:
            raise ValueError(f"csvext のヘッダが想定と違います: {header}")
        for row in reader:
            uri, asn, prefix = row[:3]
            rows.setdefault(uri, []).append((int(asn.removeprefix("AS")), prefix))

    problems, samples, as0, n_rows = [], {}, None, 0
    for uri, rs in rows.items():
        got = {a for a, _ in rs}
        if not uri.startswith("rsync://"):
            problems.append((uri, f"出どころが ROA ではない行: AS {', '.join(map(str, sorted(got)))}"))
            continue
        try:
            roa_asn, _ = read_roa(f"{rsync_dir}/{uri[len('rsync://'):]}")
        except Exception as e:
            problems.append((uri, f"ROA を読めません: {type(e).__name__}: {e}"))
            continue
        wrong = sorted({(a, p) for a, p in rs if a != roa_asn})
        if wrong:
            shown = ", ".join(f"{p} AS{a}" for a, p in wrong[:10])
            more = f" ほか {len(wrong) - 10} 件" if len(wrong) > 10 else ""
            problems.append((uri, f"ROA の AS: AS{roa_asn}  出力の行: {shown}{more}"))
            continue
        n_rows += len(rs)
        for a, p in rs:
            if p in ("1.1.1.0/24", "8.8.8.0/24"):
                samples[p] = (a, p, uri)
            if as0 is None and a == 0:
                as0 = (a, p, uri)

    if problems:
        print(f"NG ROA の AS 番号と一致しない、または照合できない ROA が {len(problems):,} 個あります（出力に出てきた ROA {len(rows):,} 個のうち）")
        for uri, line in problems[:5]:
            print(f"ROA: {uri}")
            print(f"  {line}")
        if len(problems) > 5:
            print(f"（ほか {len(problems) - 5:,} 個）")
        sys.exit(0)
    if as0 is None:
        print("NG 照合した行に次のものがありません（その処理を照合できていない）: AS0 の行")
        sys.exit(0)
    print(f"OK 出力に出てきた ROA {len(rows):,} 個すべてで、各行の AS 番号が ROA の値と一致しました（VRP {n_rows:,} 行）")
    for a, p, uri in [samples[k] for k in sorted(samples)] + [as0]:
        print(f"{p} AS{a}  ← {uri}")
except Exception as e:
    print(f"NG 照合の途中で例外: {type(e).__name__}: {e}")
PY
)

case "${out}" in
    "OK "*)
        first="${out%%$'\n'*}"
        pass "${first#OK }"
        printf '%s\n' "${out}" | tail -n +2 | sed 's/^/   /'
        ;;
    *)
        printf '%s\n' "${out}" | tail -n +2 | sed 's/^/   /'
        first="${out%%$'\n'*}"
        fail "${first#NG }"
        ;;
esac

pass "テスト完了（3.2 VRPデータの正確性：AS番号情報の正確性確認）"
