#!/usr/bin/env bash

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${EXISTING_CACHE_DIR:=./routinator-rsync-cache}"
: "${RPKI_LOG_FILE:=./32_1_check_prefix.log}"
: "${VRP_FILE:=./32_1_vrps.csv}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }

info "テスト開始（3.2 VRPデータの正確性：プレフィックス情報の正確性確認）"
info "検証内容: 出力の prefix と maxLength が、出どころの ROA に書かれた値と過不足なく一致するか"

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

info "2) 出力に出てきた ROA をキャッシュから読み、prefix と maxLength を照合します"
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


def fmt(pms, limit=10):
    s = sorted(pms)
    text = ", ".join(f"{p}-{m}" for p, m in s[:limit])
    return text + (f" ほか {len(s) - limit} 件" if len(s) > limit else "")


try:
    rows = {}
    with open(vrp_file, newline="") as f:
        reader = csv.reader(f)
        header = next(reader, [])
        if header[:4] != ["URI", "ASN", "IP Prefix", "Max Length"]:
            raise ValueError(f"csvext のヘッダが想定と違います: {header}")
        for row in reader:
            uri, asn, prefix, maxlen = row[:4]
            rows.setdefault(uri, []).append(
                (int(asn.removeprefix("AS")), str(ipaddress.ip_network(prefix)), int(maxlen)))
    all_rows = {r for rs in rows.values() for r in rs}

    problems, samples, has_v6, has_longer, n_rows = [], {}, None, None, 0
    for uri, rs in rows.items():
        got = {(p, m) for _, p, m in rs}
        if not uri.startswith("rsync://"):
            problems.append((uri, [f"出どころが ROA ではない行: {fmt(got)}"]))
            continue
        try:
            roa_asn, want = read_roa(f"{rsync_dir}/{uri[len('rsync://'):]}")
        except Exception as e:
            problems.append((uri, [f"ROA を読めません: {type(e).__name__}: {e}"]))
            continue
        extra = got - want
        # 同じ VRP が複数の ROA から来ると、csvext は URI を 1 つしか出さない。ほかの ROA の行として出ていれば欠けではない
        missing = {(p, m) for p, m in want - got if (roa_asn, p, m) not in all_rows}
        if extra or missing:
            lines = [f"ROA の値          : {fmt(want)}"]
            if extra:
                lines.append(f"ROA に無い出力    : {fmt(extra)}")
            if missing:
                lines.append(f"出力に無い ROA の値: {fmt(missing)}")
            problems.append((uri, lines))
            continue
        n_rows += len(rs)
        for p, m in got:
            net = ipaddress.ip_network(p)
            if p in ("1.1.1.0/24", "8.8.8.0/24"):
                samples[p] = (p, m, uri)
            if has_v6 is None and net.version == 6:
                has_v6 = (p, m, uri)
            if has_longer is None and m > net.prefixlen:
                has_longer = (p, m, uri)

    if problems:
        print(f"NG ROA の値と一致しない、または照合できない ROA が {len(problems):,} 個あります（出力に出てきた ROA {len(rows):,} 個のうち）")
        for uri, lines in problems[:5]:
            print(f"ROA: {uri}")
            for line in lines:
                print(f"  {line}")
        if len(problems) > 5:
            print(f"（ほか {len(problems) - 5:,} 個）")
        sys.exit(0)
    missing_kinds = [k for k, v in (("IPv6 の行", has_v6), ("maxLength が prefix 長より大きい行", has_longer)) if v is None]
    if missing_kinds:
        print(f"NG 照合した行に次のものがありません（その処理を照合できていない）: {'、'.join(missing_kinds)}")
        sys.exit(0)
    print(f"OK 出力に出てきた ROA {len(rows):,} 個すべてで、prefix と maxLength が ROA の値と過不足なく一致しました（VRP {n_rows:,} 行）")
    for p, m, uri in [samples[k] for k in sorted(samples)] + [has_v6, has_longer]:
        print(f"{p}-{m}  ← {uri}")
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

pass "テスト完了（3.2 VRPデータの正確性：プレフィックス情報の正確性確認）"
