#!/usr/bin/env bash
# 42_2_rtr_serial_query.sh
#
# 4. RTRプロトコル機能 → 4.2 RTRプロトコル動作 → 4.2.2 差分の送信 (Serial Query)
#   データが変わったときに、RTR で差分を正しく送るかを検証する。
#   空のリポジトリとローカル例外ファイル (--exceptions) だけでサーバを動かし、例外ファイルを書き換えて
#   データを A → B → C → D → E と変える (例外ファイルは検証のたびに読み直される)。
#   そのたびに、Serial Notify、Serial Query への差分、Cache Reset、/json-delta の差分が期待どおりかを見る。
#
#   キャッシュもネットワークも使わない。サーバは必ず本スクリプトが起動する。
#

set -euo pipefail

# ===== 環境変数 =====
: "${ROUTINATOR_BIN:=routinator}"
: "${RTR_PORT:=3331}"
: "${HTTP_PORT:=8331}"
: "${SERVER_WAIT:=60}"
# 1 回の書き換えが serial に反映されるまでの上限。検証は --refresh の間隔で走る
: "${SERIAL_WAIT:=60}"

# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }

# ===== クリーンアップ =====
WORK_DIR=$(mktemp -d)
REPO_DIR="${WORK_DIR}/repository"
EXCEPTIONS="${WORK_DIR}/exceptions.json"
STATE="${WORK_DIR}/state.json"
DELTA_FILE="${WORK_DIR}/json-delta.json"
SERVER_LOG="${WORK_DIR}/server.log"
CLIENT="${WORK_DIR}/rtr_client.py"
NOTIFY_OUT="${WORK_DIR}/notify.out"
NOTIFY_READY="${WORK_DIR}/notify.ready"
STARTED_PID=""
NOTIFY_PID=""
cleanup() {
    for pid in "${NOTIFY_PID}" "${STARTED_PID}"; do
        if [ -n "${pid}" ]; then
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM
mkdir -p "${REPO_DIR}"

show_server_log() {
    info "サーバーログ (末尾10行):"
    tail -n 10 "${SERVER_LOG}" | awk '{print "   [LOG] " $0}'
}

info "テスト開始（4.2 RTRプロトコル動作：差分の送信）"

for cmd in python3 curl ss; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "${cmd} コマンドが見つかりません"
done
for port in "${RTR_PORT}" "${HTTP_PORT}"; do
    if ss -tln 2>/dev/null | grep -q ":${port} "; then
        fail "ポート ${port} は既に使われています（RTR_PORT / HTTP_PORT で変えられます）"
    fi
done

# ===== RTR クライアントと判定 (python3) =====
cat > "${CLIENT}" <<'PY'
import ipaddress, json, os, socket, struct, sys, time

# 例外ファイルに書く VRP。データ A〜D はこの組み合わせ
VRPS = {
    "P1": ("192.0.2.0/24", 24, 64496),
    "P2": ("198.51.100.0/24", 24, 64496),
    "P3": ("203.0.113.0/24", 24, 64497),
    "P4": ("2001:db8::/32", 48, 64496),
}
DATA = {"A": ["P1", "P2"], "B": ["P1", "P3"], "C": ["P1", "P3", "P4"], "D": ["P3", "P4"], "E": ["P2", "P3", "P4"]}

def connect(port):
    return socket.create_connection(("127.0.0.1", port), timeout=30)

def read_pdus(s, buf=b"", until=(7, 8, 10)):
    out = []
    while True:
        while len(buf) < 8 or len(buf) < struct.unpack("!I", buf[4:8])[0]:
            d = s.recv(1 << 16)
            if not d:
                out.append({"type": "closed"})
                return out, buf
            buf += d
        ln = struct.unpack("!I", buf[4:8])[0]
        out.append(parse(buf[:ln]))
        buf = buf[ln:]
        if out[-1]["type"] in until:
            return out, buf

def parse(p):
    typ, h = p[1], struct.unpack("!H", p[2:4])[0]
    d = {"ver": p[0], "type": typ}
    if typ in (0, 3, 7, 8):
        d["session"] = h
    if typ in (0, 7):
        d["serial"] = struct.unpack("!I", p[8:12])[0]
    elif typ == 4:
        d["vrp"] = (("announce" if p[8] & 1 else "withdraw"), f"{ipaddress.IPv4Address(p[12:16])}/{p[9]}", p[10], struct.unpack("!I", p[16:20])[0])
    elif typ == 6:
        d["vrp"] = (("announce" if p[8] & 1 else "withdraw"), f"{ipaddress.IPv6Network((p[12:28], p[9]))}", p[10], struct.unpack("!I", p[28:32])[0])
    elif typ == 10:
        d["code"] = h
    return d

def query(port, pdu):
    s = connect(port)
    try:
        s.sendall(pdu)
        return read_pdus(s)[0]
    finally:
        s.close()

def reset_query():
    return struct.pack("!BBHI", 1, 2, 0, 8)

def serial_query(session, serial):
    return struct.pack("!BBHII", 1, 1, session, 12, serial)

def expect_change(spec):
    """'-P2 +P3' を [(withdraw, P2), (announce, P3)] の形にする"""
    out = []
    for w in spec.split():
        prefix, maxlen, asn = VRPS[w[1:]]
        out.append(("announce" if w[0] == "+" else "withdraw", prefix, maxlen, asn))
    return sorted(out)

def ng(msg, pdus=None):
    print("NG " + msg)
    for p in (pdus or [])[:10]:
        print(json.dumps(p))
    sys.exit()

def load_state(path):
    with open(path) as f:
        return json.load(f)

def cmd_write(path, name):
    body = {
        "slurmVersion": 1,
        "validationOutputFilters": {"prefixFilters": [], "bgpsecFilters": []},
        "locallyAddedAssertions": {
            "prefixAssertions": [{"asn": VRPS[k][2], "prefix": VRPS[k][0], "maxPrefixLength": VRPS[k][1]} for k in DATA[name]],
            "bgpsecAssertions": [],
        },
    }
    # 書きかけを読まれないよう、別名で書いてから置き換える
    with open(path + ".tmp", "w") as f:
        json.dump(body, f)
    os.replace(path + ".tmp", path)

def cmd_serial(path):
    try:
        with open(path) as f:
            d = json.load(f)
        print(d["serial"] if d.get("announced") is not None else "")
    except Exception:
        print("")

def cmd_reset(port, delta_path, state_path):
    pdus = query(port, reset_query())
    head, body, eod = pdus[0], pdus[1:-1], pdus[-1]
    if head["type"] != 3 or eod["type"] != 7:
        ng("Reset Query に Cache Response と End of Data が返りません", pdus)
    got = sorted(p.get("vrp") for p in body)
    want = expect_change("+P1 +P2")
    if got != want:
        ng(f"データ A の全件が期待と違います（届いた {got}、期待 {want}）")
    with open(delta_path) as f:
        http = json.load(f)
    if http["serial"] != eod["serial"]:
        ng(f"End of Data の serial={eod['serial']} と /json-delta の serial={http['serial']} が違います")
    with open(state_path, "w") as f:
        json.dump({"session": eod["session"], "serial": eod["serial"], "http_session": http["session"]}, f)
    print(f"OK データ A の全件（VRP 2 件）を受け取りました（session={eod['session']} serial={eod['serial']}）")

def cmd_notify(port, state_path, ready_path, timeout, offset):
    st = load_state(state_path)
    want = st["serial"] + int(offset)
    s = connect(port)
    s.sendall(reset_query())
    _, buf = read_pdus(s)
    open(ready_path, "w").close()
    s.settimeout(float(timeout))
    try:
        pdus, _ = read_pdus(s, buf, until=(0, 10))
    except socket.timeout:
        ng(f"{timeout} 秒待っても Serial Notify が届きません")
    finally:
        s.close()
    n = pdus[-1]
    if n["type"] != 0 or n["session"] != st["session"] or n["serial"] != want:
        ng(f"Serial Notify (session={st['session']} serial={want}) が届きません", pdus)
    print(f"OK 接続中のクライアントに Serial Notify（serial={n['serial']}）が届きました")

def cmd_delta(port, state_path, from_off, spec, to_off):
    st = load_state(state_path)
    frm, to = st["serial"] + int(from_off), st["serial"] + int(to_off)
    pdus = query(port, serial_query(st["session"], frm))
    head, body, eod = pdus[0], pdus[1:-1], pdus[-1]
    if head["type"] != 3 or eod["type"] != 7 or head["session"] != st["session"]:
        ng(f"serial={frm} からの Serial Query に、差分 (Cache Response … End of Data) が返りません", pdus)
    got = sorted(p.get("vrp") for p in body)
    want = expect_change(spec)
    if got != want:
        ng(f"serial={frm} からの差分が期待と違います（届いた {got}、期待 {want}）", body)
    if eod["serial"] != to:
        ng(f"差分の End of Data の serial={eod['serial']} が {to} ではありません")
    what = spec.replace("+", "announce ").replace("-", "withdraw ") if spec else "空"
    print(f"OK serial={frm} からの Serial Query に差分（{what}）と End of Data（serial={to}）が返りました")

def cmd_cache_reset(port, state_path, from_off, session_off, why):
    st = load_state(state_path)
    session = (st["session"] + int(session_off)) % 65536
    frm = st["serial"] + int(from_off)
    pdus = query(port, serial_query(session, frm))
    if len(pdus) != 1 or pdus[0]["type"] != 8:
        ng(f"{why}（session={session} serial={frm}）の Serial Query に Cache Reset が返りません", pdus)
    print(f"OK {why}（session={session} serial={frm}）の Serial Query に Cache Reset が返りました")

def cmd_http_delta(path, state_path, spec, to_off):
    st = load_state(state_path)
    with open(path) as f:
        d = json.load(f)
    def norm(items, flag):
        return [(flag, a["prefix"], a["maxLength"], int(a["asn"].removeprefix("AS"))) for a in items if a["type"] == "routeOrigin"]
    got = sorted(norm(d.get("announced", []), "announce") + norm(d.get("withdrawn", []), "withdraw"))
    want = expect_change(spec)
    if d.get("reset") is not False or got != want or d.get("serial") != st["serial"] + int(to_off):
        ng(f"/json-delta の差分が RTR と合いません（reset={d.get('reset')} serial={d.get('serial')} 届いた {got}、期待 {want}）")
    print("OK /json-delta の差分も RTR と同じでした（reset=false）")

def cmd_metrics(path):
    with open(path) as f:
        c = json.load(f)["rtr"]["clients"].get("127.0.0.1")
    print("記録なし" if c is None else f"resetQueries={c['resetQueries']} serialQueries={c['serialQueries']} serial={c['serial']}")

try:
    {"write": cmd_write, "serial": cmd_serial, "reset": cmd_reset, "notify": cmd_notify,
     "delta": cmd_delta, "cache-reset": cmd_cache_reset, "http-delta": cmd_http_delta,
     "metrics": cmd_metrics}[sys.argv[1]](*sys.argv[2:])
except SystemExit:
    raise
except Exception as e:
    print(f"NG 判定の途中で例外: {type(e).__name__}: {e}")
PY

# 出力の 1 行目が "OK ..." なら PASS、それ以外は出力をすべて出して FAIL
report() {
    local out="$1"
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
judge() {
    report "$(python3 "${CLIENT}" "$@" 2>&1 || true)"
}

# 例外ファイルをデータ $1 に書き換え、serial が「最初 + $2」になるまで待つ
change_data() {
    local name="$1" want waited=0 now
    want=$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serial"])' "${STATE}") + $2 ))
    python3 "${CLIENT}" write "${EXCEPTIONS}" "${name}"
    while :; do
        curl -s --max-time 10 -o "${DELTA_FILE}" "http://127.0.0.1:${HTTP_PORT}/json-delta" 2>/dev/null || true
        now=$(python3 "${CLIENT}" serial "${DELTA_FILE}")
        [ "${now}" = "${want}" ] && break
        if [ "${waited}" -ge "${SERIAL_WAIT}" ]; then
            show_server_log
            fail "データ ${name} に書き換えて ${SERIAL_WAIT} 秒待っても serial が ${want} になりません（今: '${now}'）"
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    info "   データ ${name} に書き換えました（serial=${want}、${waited}秒）"
}

# ===== サーバー起動 (データ A) =====
python3 "${CLIENT}" write "${EXCEPTIONS}" A
info "サーバーを起動します（RTR ${RTR_PORT}、HTTP ${HTTP_PORT}、空のリポジトリ + 例外ファイル）"
"${ROUTINATOR_BIN}" --repository-dir "${REPO_DIR}" --disable-rrdp --disable-rsync --exceptions "${EXCEPTIONS}" \
    server --rtr "127.0.0.1:${RTR_PORT}" --http "127.0.0.1:${HTTP_PORT}" --rtr-client-metrics \
    --refresh 10 --history 3 \
    > "${SERVER_LOG}" 2>&1 &
STARTED_PID=$!

WAITED=0
until [ -n "$(curl -s --max-time 5 -o "${DELTA_FILE}" "http://127.0.0.1:${HTTP_PORT}/json-delta" 2>/dev/null; python3 "${CLIENT}" serial "${DELTA_FILE}")" ]; do
    if [ "${WAITED}" -ge "${SERVER_WAIT}" ] || ! kill -0 "${STARTED_PID}" 2>/dev/null; then
        show_server_log
        fail "${SERVER_WAIT} 秒以内に初回の検証が終わりませんでした"
    fi
    sleep 1
    WAITED=$(( WAITED + 1 ))
done

#  1) 全件 (データ A)
info "1) Reset Query（データ A: P1・P2）"
judge reset "${RTR_PORT}" "${DELTA_FILE}" "${STATE}"
HTTP_SESSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["http_session"])' "${STATE}")
SERIAL0=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serial"])' "${STATE}")

#  2) Serial Notify (A → B)
info "2) 接続したままのクライアントへの Serial Notify（A → B: P2 を消して P3 を足す）"
python3 "${CLIENT}" notify "${RTR_PORT}" "${STATE}" "${NOTIFY_READY}" "$(( SERIAL_WAIT + 10 ))" 1 > "${NOTIFY_OUT}" 2>&1 &
NOTIFY_PID=$!
WAITED=0
until [ -e "${NOTIFY_READY}" ]; do
    if [ "${WAITED}" -ge 30 ]; then
        cat "${NOTIFY_OUT}"
        fail "Serial Notify を待つクライアントが接続できませんでした"
    fi
    sleep 1
    WAITED=$(( WAITED + 1 ))
done
change_data B 1
wait "${NOTIFY_PID}" || true
NOTIFY_PID=""
report "$(cat "${NOTIFY_OUT}")"

#  3〜5) 差分
info "3) Serial Query（A からの差分）"
judge delta "${RTR_PORT}" "${STATE}" 0 "-P2 +P3" 1
info "4) Serial Query（最新の serial から。差分は空）"
judge delta "${RTR_PORT}" "${STATE}" 1 "" 1
info "5) /json-delta（A からの差分）"
curl -s --max-time 10 -o "${DELTA_FILE}" "http://127.0.0.1:${HTTP_PORT}/json-delta?session=${HTTP_SESSION}&serial=${SERIAL0}" || true
judge http-delta "${DELTA_FILE}" "${STATE}" "-P2 +P3" 1

#  6〜8) 複数の差分のまとめと Cache Reset
# 差分は 3 つまで保持 (--history 3)。4 回目の書き換えで A → B の差分が落ちる。
# 0.16.1 は「相手の serial で終わる差分」が残っていないと Cache Reset にするので、
# まとめは C から、Cache Reset は A から確かめる (どちらも保持の数え方に左右されない)
info "6) さらに 3 回書き換え（B → C: P4 を足す、C → D: P1 を消す、D → E: P2 を足す）"
change_data C 2
change_data D 3
change_data E 4
info "7) Serial Query（C からの差分。2 つの差分をまとめたもの）"
judge delta "${RTR_PORT}" "${STATE}" 2 "-P1 +P2" 4
info "8) Serial Query（差分が残っていない A から / 違う session）"
judge cache-reset "${RTR_PORT}" "${STATE}" 0 0 "差分が残っていない serial から"
judge cache-reset "${RTR_PORT}" "${STATE}" 4 1 "違う session"

# サーバ側の記録 (--rtr-client-metrics)。判定には使わない
STATUS_FILE="${WORK_DIR}/status.json"
if curl -s --max-time 10 -o "${STATUS_FILE}" "http://127.0.0.1:${HTTP_PORT}/api/v1/status"; then
    info "サーバ側の記録 (127.0.0.1): $(python3 "${CLIENT}" metrics "${STATUS_FILE}" 2>&1 || true)"
fi

pass "テスト完了（4.2 RTRプロトコル動作：差分の送信）"
