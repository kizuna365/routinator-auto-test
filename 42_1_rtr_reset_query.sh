#!/usr/bin/env bash
# 42_1_rtr_reset_query.sh
#
# 4. RTRプロトコル機能 → 4.2 RTRプロトコル動作 → 4.2.1 全件の送信 (Reset Query)
#   Reset Query に対して、検証済みのデータを全件、RTR の版 (v0・v1・v2) ごとに正しい形で送るかを検証する。
#   rsync のキャッシュ (実データ) に、ローカル例外ファイル (--exceptions) で値の分かっている目印を足し、
#   目印がその値で届くか、件数が /json-delta と一致するか、版ごとに送ってよいものだけを送るかを見る。
#
#   サーバは必ず本スクリプトが起動する (常駐のデーモンではデータを制御できないため)。
#   REPOSITORY_DIR に rsync のキャッシュ (21_1 の成果物) を渡す。
#

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${REPOSITORY_DIR:=}"
: "${RTR_PORT:=3330}"
: "${HTTP_PORT:=8330}"
: "${SERVER_WAIT:=60}"
: "${DATA_WAIT:=180}"
# End of Data で送られるかを見るため、retry と expire は既定 (600 / 7200) と違う値にする
: "${RTR_RETRY:=900}"
: "${RTR_EXPIRE:=5400}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }

# ===== クリーンアップ =====
WORK_DIR=$(mktemp -d)
EXCEPTIONS="${WORK_DIR}/exceptions.json"
DELTA_FILE="${WORK_DIR}/json-delta.json"
SERVER_LOG="${WORK_DIR}/server.log"
CLIENT="${WORK_DIR}/rtr_client.py"
STARTED_PID=""
cleanup() {
    if [ -n "${STARTED_PID}" ]; then
        kill "${STARTED_PID}" 2>/dev/null || true
        wait "${STARTED_PID}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

show_server_log() {
    info "サーバーログ (末尾10行):"
    tail -n 10 "${SERVER_LOG}" | awk '{print "   [LOG] " $0}'
}

info "テスト開始（4.2 RTRプロトコル動作：全件の送信）"

for cmd in python3 curl ss; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "${cmd} コマンドが見つかりません"
done
if [ -z "${REPOSITORY_DIR}" ] || [ ! -d "${REPOSITORY_DIR}" ]; then
    fail "REPOSITORY_DIR に rsync のキャッシュを指定してください（今: '${REPOSITORY_DIR}'）"
fi
for port in "${RTR_PORT}" "${HTTP_PORT}"; do
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
        fail "ポート ${port} は既に使われています（RTR_PORT / HTTP_PORT で変えられます）"
    fi
done

# ===== RTR クライアントと判定 (python3) =====
cat > "${CLIENT}" <<'PY'
import base64, ipaddress, json, socket, struct, sys

# 例外ファイルで足す目印。シェル側の例外ファイルと同じ値
MARK_V4 = ("192.0.2.0/24", 24, 64496)
MARK_V6 = ("2001:db8::/32", 48, 64496)
MARK_RK_ASN = 64496
MARK_RK_SKI = base64.urlsafe_b64decode("PXwfTLC2lvU-REATzHC0myozUI4=").hex().upper()
MARK_ASPA = (64496, [64497, 64498])
ALLOWED = {0: {4, 6}, 1: {4, 6, 9}, 2: {4, 6, 9, 11}}

def query(port, pdu):
    """PDU を 1 つ送り、Cache Response の終わり (End of Data / Cache Reset / Error Report) まで読む"""
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    s.sendall(pdu)
    # 全件は数十 MB になるので、受け取った分は切り詰めずに読む位置 (pos) だけを進める
    data, pos, out = bytearray(), 0, []
    try:
        while True:
            while len(data) - pos < 8 or len(data) - pos < struct.unpack_from("!I", data, pos + 4)[0]:
                d = s.recv(1 << 20)
                if not d:
                    out.append({"type": "closed"})
                    return out
                data += d
            ln = struct.unpack_from("!I", data, pos + 4)[0]
            out.append(parse(bytes(data[pos:pos + ln])))
            pos += ln
            if out[-1]["type"] in (7, 8, 10):
                return out
    finally:
        s.close()

def parse(p):
    ver, typ, h = p[0], p[1], struct.unpack("!H", p[2:4])[0]
    d = {"ver": ver, "type": typ, "len": len(p)}
    if typ in (0, 3, 7, 8):
        d["session"] = h
    if typ == 4:
        d.update(flags=p[8], prefix=f"{ipaddress.IPv4Address(p[12:16])}/{p[9]}", maxlen=p[10], asn=struct.unpack("!I", p[16:20])[0])
    elif typ == 6:
        d.update(flags=p[8], prefix=f"{ipaddress.IPv6Network((p[12:28], p[9]))}", maxlen=p[10], asn=struct.unpack("!I", p[28:32])[0])
    elif typ == 9:
        d.update(flags=p[2], ski=p[8:28].hex().upper(), asn=struct.unpack("!I", p[28:32])[0])
    elif typ == 11:
        d.update(flags=p[2], customer=struct.unpack("!I", p[8:12])[0],
                 providers=[struct.unpack("!I", p[i:i + 4])[0] for i in range(12, len(p), 4)])
    elif typ in (0, 7):
        d["serial"] = struct.unpack("!I", p[8:12])[0]
        if typ == 7 and len(p) >= 24:
            d["refresh"], d["retry"], d["expire"] = struct.unpack("!III", p[12:24])
    elif typ == 10:
        d["code"] = h
    return d

def reset_query(ver):
    return struct.pack("!BBHI", ver, 2, 0, 8)

def brief(pdus, n=5):
    return "\n".join(json.dumps(p) for p in pdus[:n]) + (f"\n... ほか {len(pdus) - n} 個" if len(pdus) > n else "")

def ng(msg, *details):
    print("NG " + msg)
    for x in details:
        print(x)
    sys.exit()

def cmd_has_data(path):
    try:
        with open(path) as f:
            print("yes" if json.load(f).get("announced") else "no")
    except Exception:
        print("no")

def cmd_nodata(port):
    pdus = query(port, reset_query(1))
    if pdus[0]["type"] == 10 and pdus[0]["code"] == 2:
        print("OK 初回の検証の前は Error Report (No Data Available) が返りました")
    else:
        ng("初回の検証の前なのに Error Report (No Data Available) が返りません", brief(pdus))

def cmd_full(port, ver, delta_path, slurm_aspa, retry, expire):
    ver, retry, expire = int(ver), int(retry), int(expire)
    with open(delta_path) as f:
        delta = json.load(f)
    want = {"routeOrigin": 0, "routerKey": 0, "aspa": 0}
    for a in delta["announced"]:
        want[a["type"]] = want.get(a["type"], 0) + 1
    pdus = query(port, reset_query(ver))
    head, body, eod = pdus[0], pdus[1:-1], pdus[-1]
    if head["type"] != 3 or eod["type"] != 7:
        ng(f"v{ver}: Cache Response で始まり End of Data で終わる形になっていません", brief(pdus), brief(pdus[-1:]))
    if head["session"] != eod["session"]:
        ng(f"v{ver}: session が Cache Response ({head['session']}) と End of Data ({eod['session']}) で違います")
    bad_ver = [p for p in pdus if p["ver"] != ver]
    if bad_ver:
        ng(f"v{ver}: 版が {ver} でない PDU が {len(bad_ver)} 個あります", brief(bad_ver))
    bad_type = [p for p in body if p["type"] not in ALLOWED[ver]]
    if bad_type:
        ng(f"v{ver}: v{ver} で送ってはいけない種類の PDU が {len(bad_type)} 個あります", brief(bad_type))
    not_announce = [p for p in body if p["flags"] & 1 != 1]
    if not_announce:
        ng(f"v{ver}: 全件の応答に announce でない PDU が {len(not_announce)} 個あります", brief(not_announce))
    got = {"routeOrigin": sum(p["type"] in (4, 6) for p in body),
           "routerKey": sum(p["type"] == 9 for p in body),
           "aspa": sum(p["type"] == 11 for p in body)}
    expect = dict(want)
    if ver < 1:
        expect["routerKey"] = 0
    if ver < 2:
        expect["aspa"] = 0
    if got != expect:
        ng(f"v{ver}: 件数が /json-delta と合いません（RTR {got}、期待 {expect}、/json-delta {want}）")
    if eod["serial"] != delta["serial"]:
        ng(f"v{ver}: End of Data の serial={eod['serial']} が /json-delta の serial={delta['serial']} と違います")
    if ver == 0:
        if eod["len"] != 12:
            ng(f"v0: End of Data の長さが {eod['len']} バイトです（v0 は 12 バイト）")
        timing = ""
    else:
        if eod["len"] != 24:
            ng(f"v{ver}: End of Data の長さが {eod['len']} バイトです（v1 以降は 24 バイト）")
        # refresh は次のデータが出そうな時刻の目安で、設定値を超えることがある。RFC 8210 の範囲だけを見る
        if not (1 <= eod["refresh"] <= 86400) or eod["retry"] != retry or eod["expire"] != expire:
            ng(f"v{ver}: End of Data の時間値が合いません（refresh={eod['refresh']} は 1〜86400、"
               f"retry={eod['retry']} は {retry}、expire={eod['expire']} は {expire} のはず）")
        timing = f" refresh={eod['refresh']} retry={eod['retry']} expire={eod['expire']}"
    marks = []
    for (prefix, maxlen, asn), typ in ((MARK_V4, 4), (MARK_V6, 6)):
        if not any(p["type"] == typ and p["prefix"] == prefix and p["maxlen"] == maxlen and p["asn"] == asn for p in body):
            ng(f"v{ver}: 目印の VRP（{prefix} maxLength {maxlen} AS{asn}）が届いていません")
    marks.append("VRP")
    if ver >= 1:
        if not any(p["type"] == 9 and p["asn"] == MARK_RK_ASN and p["ski"] == MARK_RK_SKI for p in body):
            ng(f"v{ver}: 目印の router key（AS{MARK_RK_ASN}、SKI {MARK_RK_SKI}）が届いていません")
        marks.append("router key")
    if ver >= 2 and slurm_aspa == "yes":
        c, prov = MARK_ASPA
        if not any(p["type"] == 11 and p["customer"] == c and sorted(p["providers"]) == prov for p in body):
            ng(f"v2: 目印の ASPA（AS{c} → {prov}）が届いていません",
               brief([p for p in body if p["type"] == 11 and p["customer"] == c]))
        marks.append("ASPA")
    counts = f"VRP {got['routeOrigin']} 件"
    if ver >= 1:
        counts += f"・router key {got['routerKey']} 件"
    if ver >= 2:
        counts += f"・ASPA {got['aspa']} 件"
    print(f"OK v{ver}: {counts}が /json-delta と一致、目印（{'・'.join(marks)}）あり、"
          f"End of Data serial={eod['serial']}{timing}（{eod['len']} バイト）")

def cmd_badver(port):
    pdus = query(port, reset_query(3))
    if pdus[0]["type"] == 10 and pdus[0]["code"] == 4:
        print(f"OK 未対応の版 (v3) には Error Report (Unsupported Protocol Version) が v{pdus[0]['ver']} で返りました")
    else:
        ng("未対応の版 (v3) に Error Report (Unsupported Protocol Version) が返りません", brief(pdus))

def cmd_metrics(path):
    with open(path) as f:
        c = json.load(f)["rtr"]["clients"].get("127.0.0.1")
    if c is None:
        print("記録なし")
    else:
        print(f"resetQueries={c['resetQueries']} serialQueries={c['serialQueries']} written={c['written']} bytes")

try:
    {"has-data": cmd_has_data, "nodata": cmd_nodata, "full": cmd_full,
     "badver": cmd_badver, "metrics": cmd_metrics}[sys.argv[1]](*sys.argv[2:])
except SystemExit:
    raise
except Exception as e:
    print(f"NG 判定の途中で例外: {type(e).__name__}: {e}")
PY

# 結果の 1 行目が "OK ..." なら PASS、それ以外は出力をすべて出して FAIL
judge() {
    local out
    out=$(python3 "${CLIENT}" "$@" 2>&1 || true)
    case "${out}" in
        "OK "*) pass "${out#OK }" ;;
        *)
            printf '%s\n' "${out}" | sed 's/^/   /'
            show_server_log
            local first="${out%%$'\n'*}"
            fail "${first#NG }"
            ;;
    esac
}

# ===== 版による違い =====
# 0.15 系は ASPA と BGPsec が既定で無効で、例外ファイルで ASPA を足せない (SLURM の版 2 の読み込みは 0.16 から)
ROUTINATOR_HELP="$("${ROUTINATOR_BIN}" --help 2>&1 || true)"
case "${ROUTINATOR_HELP}" in
    *--enable-aspa*)
        GLOBAL_OPTS=(--enable-aspa --enable-bgpsec)
        SLURM_ASPA=no
        ;;
    *)
        GLOBAL_OPTS=()
        SLURM_ASPA=yes
        ;;
esac

# ===== ローカル例外ファイル (目印) =====
if [ "${SLURM_ASPA}" = yes ]; then
    SLURM_HEAD='"slurmVersion": 2'
    ASPA_FILTERS=', "aspaFilters": []'
    ASPA_ASSERTIONS=', "aspaAssertions": [{"customerAsn": 64496, "providerAsns": [64497, 64498]}]'
else
    SLURM_HEAD='"slurmVersion": 1'
    ASPA_FILTERS=''
    ASPA_ASSERTIONS=''
    info "この版は例外ファイルで ASPA を足せないため、ASPA は件数の一致だけを見ます"
fi
cat > "${EXCEPTIONS}" <<EOF
{
  ${SLURM_HEAD},
  "validationOutputFilters": {"prefixFilters": [], "bgpsecFilters": []${ASPA_FILTERS}},
  "locallyAddedAssertions": {
    "prefixAssertions": [
      {"asn": 64496, "prefix": "192.0.2.0/24", "maxPrefixLength": 24},
      {"asn": 64496, "prefix": "2001:db8::/32", "maxPrefixLength": 48}
    ],
    "bgpsecAssertions": [
      {"asn": 64496, "SKI": "PXwfTLC2lvU-REATzHC0myozUI4",
       "routerPublicKey": "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEyg-2HFG_tdYF1fsdp6LZRDsB2LgY8-0aA0ZkWa8zDYNjoaDVL5vGZvomvf0fhndq1RFk6FcEIBfPwHHeHgfVyQ"}
    ]${ASPA_ASSERTIONS}
  }
}
EOF

# ===== サーバー起動 =====
info "サーバーを起動します（RTR ${RTR_PORT}、HTTP ${HTTP_PORT}、キャッシュ ${REPOSITORY_DIR}）"
"${ROUTINATOR_BIN}" ${GLOBAL_OPTS[@]+"${GLOBAL_OPTS[@]}"} \
    --repository-dir "${REPOSITORY_DIR}" --disable-rrdp --disable-rsync --exceptions "${EXCEPTIONS}" \
    server --rtr "127.0.0.1:${RTR_PORT}" --http "127.0.0.1:${HTTP_PORT}" --rtr-client-metrics \
    --retry "${RTR_RETRY}" --expire "${RTR_EXPIRE}" \
    > "${SERVER_LOG}" 2>&1 &
STARTED_PID=$!

WAITED=0
until ss -tln 2>/dev/null | grep -q ":${RTR_PORT} "; do
    if [ "${WAITED}" -ge "${SERVER_WAIT}" ] || ! kill -0 "${STARTED_PID}" 2>/dev/null; then
        show_server_log
        fail "RTR ポート ${RTR_PORT} が開きませんでした"
    fi
    sleep 1
    WAITED=$(( WAITED + 1 ))
done

#  1) 初回の検証の前
info "1) 初回の検証の前の Reset Query"
judge nodata "${RTR_PORT}"

# ── データが利用可能になるまで待つ ──
info "データが利用可能になるまで待機します（最大 ${DATA_WAIT} 秒）"
WAITED=0
until [ "$(curl -s --max-time 30 -o "${DELTA_FILE}" "http://127.0.0.1:${HTTP_PORT}/json-delta" 2>/dev/null; python3 "${CLIENT}" has-data "${DELTA_FILE}")" = yes ]; do
    if [ "${WAITED}" -ge "${DATA_WAIT}" ]; then
        show_server_log
        fail "${DATA_WAIT} 秒待っても /json-delta の announced が空のままです"
    fi
    sleep 5
    WAITED=$(( WAITED + 5 ))
done
info "   データが利用可能になりました（${WAITED}秒）"

#  2〜4) 版ごとの全件
info "2) v1 の Reset Query"
judge full "${RTR_PORT}" 1 "${DELTA_FILE}" "${SLURM_ASPA}" "${RTR_RETRY}" "${RTR_EXPIRE}"
info "3) v0 の Reset Query"
judge full "${RTR_PORT}" 0 "${DELTA_FILE}" "${SLURM_ASPA}" "${RTR_RETRY}" "${RTR_EXPIRE}"
info "4) v2 の Reset Query"
judge full "${RTR_PORT}" 2 "${DELTA_FILE}" "${SLURM_ASPA}" "${RTR_RETRY}" "${RTR_EXPIRE}"

#  5) 未対応の版
info "5) 未対応の版 (v3) の Reset Query"
judge badver "${RTR_PORT}"

# サーバ側の記録 (--rtr-client-metrics)。判定には使わない
STATUS_FILE="${WORK_DIR}/status.json"
if curl -s --max-time 10 -o "${STATUS_FILE}" "http://127.0.0.1:${HTTP_PORT}/api/v1/status"; then
    info "サーバ側の記録 (127.0.0.1): $(python3 "${CLIENT}" metrics "${STATUS_FILE}" 2>&1 || true)"
fi

pass "テスト完了（4.2 RTRプロトコル動作：全件の送信）"
