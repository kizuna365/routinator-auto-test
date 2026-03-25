#!/usr/bin/env bash
# 21_3_check_all_rir.sh
#
# 2. データ取得と検証機能 → 2.1 RPKIデータの取得
#   各RIRリポジトリからのデータダウンロード確認テスト
#

#   21_1_fetch_rsync (Rsync) と 21_2_fetch_rrdp (RRDP) で生成された
#   それぞれのJSONファイルを解析し、5つのRIRすべてのデータが含まれているか検証する。

set -euo pipefail

# ===== 環境変数 =====
: "${RSYNC_JSON:=./routinator-rsync-out/vrps.json}"
: "${RRDP_JSON:=./routinator-rrdp-out/vrps.json}" 


# ===== 表示用ヘルパ =====
pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }


# クリーンアップ（終了時に一時ファイルを削除）
VALIDATOR_SCRIPT=""
cleanup() {
    if [ -n "$VALIDATOR_SCRIPT" ] && [ -f "$VALIDATOR_SCRIPT" ]; then
        rm -f "$VALIDATOR_SCRIPT"
    fi
}
trap cleanup EXIT

info "テスト開始（2.1 RPKIデータの取得：各RIRリポジトリからのデータダウンロード 確認テスト）"

info "1) 検証ロジック(Python3)の準備"

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 が見つかりません。"
fi

VALIDATOR_SCRIPT=$(mktemp)

# Pythonコードを一時ファイルに書き出す
# 引数(sys.argv[1])でJSONファイルのパスを受け取る仕様にする
cat <<'EOF' > "$VALIDATOR_SCRIPT"
import json
import sys
from pathlib import Path

# 引数チェック
if len(sys.argv) < 2:
    print("ERROR: JSONファイルのパスが引数として渡されていません")
    sys.exit(1)

json_path = Path(sys.argv[1])
print(f"INFO: 解析対象: {json_path}")

try:
    # ファイル読み込み
    text = json_path.read_text(encoding="utf-8")
    if not text.strip():
        print("ERROR: JSON ファイルの内容が空です")
        sys.exit(1)
    data = json.loads(text)
except FileNotFoundError:
    print(f"ERROR: ファイルが見つかりません: {json_path}")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: JSON のパースに失敗しました: {e}")
    sys.exit(1)

# "roas" キーからリストを取得 
roas = data.get("roas")
if roas is None:
    roas = data.get("vrps", [])

if not isinstance(roas, list):
    print("ERROR: JSON 内の roas/vrps フィールドが配列ではありません")
    sys.exit(1)

print(f"INFO: VRPデータ件数: {len(roas)}")

# TAの集計
detected_tas = set()
required_ris = {"AFRINIC", "APNIC", "ARIN", "LACNIC", "RIPE"}

for v in roas:
    if not isinstance(v, dict):
        continue
    ta = v.get("ta")
    if ta:
        detected_tas.add(str(ta).upper())

# 結果判定
if detected_tas:
    print("INFO: 検出されたTA:", ", ".join(sorted(detected_tas)))
else:
    print("WARN: JSON 内に TA 情報が見つかりませんでした")

missing = required_ris - detected_tas

if missing:
    print("FAIL: 不足しているRIRがあります:", ", ".join(sorted(missing)))
    sys.exit(1)
else:
    print("SUCCESS: 全5地域のRIR (AFRINIC, APNIC, ARIN, LACNIC, RIPE) からデータを確認しました。")
    sys.exit(0)
EOF

pass "検証用スクリプトを作成しました"


info "2) rsyncプロトコル取得データの検証"

rsync_bit=0
rrdp_bit=0

if [ ! -f "$RSYNC_JSON" ]; then
    warn "rsync版の出力ファイルが見つかりません: $RSYNC_JSON"
    warn "スキップします (Step 21_1_fetch_rsync.sh を実行してください)"
else
    if python3 "$VALIDATOR_SCRIPT" "$RSYNC_JSON"; then
        pass "rsync版: 全RIRからのデータ取得を確認しました"
    else
        warn "rsync版: カバレッジテスト失敗"
        rsync_bit=-1
    fi
fi

info "3) RRDPプロトコル取得データの検証"

if [ ! -f "$RRDP_JSON" ]; then
    warn "RRDP版の出力ファイルが見つかりません: $RRDP_JSON"
    warn "スキップします (Step 21_2_fetch_rrdp.sh を実行してください)"
else
    if python3 "$VALIDATOR_SCRIPT" "$RRDP_JSON"; then
        pass "RRDP版: 全RIRからのデータ取得を確認しました"
    else
        warn "RRDP版: カバレッジテスト失敗"
        rrdp_bit=-1
    fi
fi


if [ "$rsync_bit" -eq -1 ] && [ "$rrdp_bit" -eq -1 ]; then
    fail "rsync版とRRDP版の両方でカバレッジテストに失敗しました"
elif [ "$rsync_bit" -eq -1 ]; then
    fail "rsync版でカバレッジテストに失敗しました"
elif [ "$rrdp_bit" -eq -1 ]; then
    fail "RRDP版でカバレッジテストに失敗しました"
else
    pass "テスト完了（2.1 RPKIデータの取得：各RIRリポジトリからのデータダウンロード 確認テスト）"
fi
