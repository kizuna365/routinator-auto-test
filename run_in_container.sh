#!/usr/bin/env bash
# run_in_container.sh – テストスクリプトを Docker コンテナ内で実行する共通ラッパー
#
# 使い方:
#   ./run_in_container.sh <script_name.sh> [args...]
#
# 例:
#   ./run_in_container.sh 11_1_pkg_install_check.sh
#   ./run_in_container.sh 22_1_check_cert_chain_validation.sh
#
# 環境変数:
#   IMAGE_NAME – Docker イメージ名 (デフォルト: routinator-test)
#   NO_CACHE   – "1" を指定すると --no-cache でビルド
#   TCP_RMEM   – コンテナ内の net.ipv4.tcp_rmem (デフォルト: "4096 87380 16777216")
#   TCP_WMEM   – コンテナ内の net.ipv4.tcp_wmem (デフォルト: "4096 65536 16777216")
#   TCP_CC     – 輻輳制御アルゴリズム (例: bbr。未指定ならカーネル既定のまま)
#   NO_SYSCTL  – "1" を指定すると sysctl 調整を一切行わない

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${IMAGE_NAME:=routinator-test}"

# ═══════════════════════════════════════════════════════════
# コンテナ内 TCP バッファの調整
#
# GitHub Actions (米国) から RIR リポジトリへの RTT は数〜数十ms なので、
# カーネル既定の受信バッファ上限 (tcp_rmem の 3 番目 = 6MiB) でも帯域遅延積を
# 賄えて fetch が timeout しなかった。日本の実機からだと RTT が 100〜250ms に
# なり、1 コネクションのスループットが受信ウィンドウで頭打ちになる
# (RTT 200ms / 6MiB なら理論上限が約 240Mbps、実効はさらに低い)。
# RRDP の snapshot は数百MB あるため、ここが 21_* の timeout の原因になる。
#
# 注意: 新しい network namespace は、ホストの sysctl 値を継承せずカーネルの
# コンパイル時デフォルトから始まる。つまりホストで tcp_rmem を上げても
# コンテナには効かないので、docker run --sysctl で明示的に渡す必要がある。
#
# net.core.{r,w}mem_max は namespace 化されていない（per-netns 化の提案は
# 上流で却下された）ため --sysctl では設定できない。ただしこれらは
# setsockopt(SO_RCVBUF/SO_SNDBUF) を明示的に呼ぶアプリの上限を決める値で、
# routinator (reqwest) や rsync のように自動チューニングに任せる実装には
# 影響しない。コンテナはホストのグローバル値をそのまま参照するので、
# ホスト側で 16MiB にしてあれば追加の作業は不要。
# ═══════════════════════════════════════════════════════════
TCP_RMEM="${TCP_RMEM:-4096 87380 16777216}"
TCP_WMEM="${TCP_WMEM:-4096 65536 16777216}"
TCP_CC="${TCP_CC:-}"

SYSCTL_OPTS=()

sysctl_candidates() {
    echo "net.ipv4.tcp_rmem=${TCP_RMEM}"
    echo "net.ipv4.tcp_wmem=${TCP_WMEM}"
    echo "net.ipv4.tcp_slow_start_after_idle=0"
    if [ -n "${TCP_CC}" ]; then
        echo "net.ipv4.tcp_congestion_control=${TCP_CC}"
    fi
}

setup_sysctl_opts() {
    SYSCTL_OPTS=()

    if [ "${NO_SYSCTL:-0}" = "1" ]; then
        echo "  NO_SYSCTL=1 のため TCP バッファ調整をスキップします"
        return
    fi

    local -a candidates=()
    local kv
    while IFS= read -r kv; do
        if [ -n "${kv}" ]; then
            candidates+=("${kv}")
        fi
    done < <(sysctl_candidates)

    # まず全項目をまとめて適用できるか試す
    local -a all_opts=()
    for kv in "${candidates[@]}"; do
        all_opts+=(--sysctl "${kv}")
    done

    if docker run --rm "${all_opts[@]}" "${IMAGE_NAME}" true >/dev/null 2>&1; then
        SYSCTL_OPTS=("${all_opts[@]}")
        for kv in "${candidates[@]}"; do
            echo "  applied: ${kv}"
        done
    else
        # 1 項目ずつ判定し、このカーネルで設定できないものを落とす
        for kv in "${candidates[@]}"; do
            if docker run --rm --sysctl "${kv}" "${IMAGE_NAME}" true >/dev/null 2>&1; then
                SYSCTL_OPTS+=(--sysctl "${kv}")
                echo "  applied: ${kv}"
            else
                echo "  skipped: ${kv} (このカーネル/Docker では設定できません)"
            fi
        done
    fi
}

show_tcp_settings() {
    echo "  --- host ---"
    printf '    %-22s %s\n' "tcp_rmem"   "$(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "tcp_wmem"   "$(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "core.rmem_max" "$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "core.wmem_max" "$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo N/A)"
    echo "  --- container ---"
    docker run --rm ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} "${IMAGE_NAME}" bash -c '
        printf "    %-22s %s\n" "tcp_rmem"      "$(cat /proc/sys/net/ipv4/tcp_rmem)"
        printf "    %-22s %s\n" "tcp_wmem"      "$(cat /proc/sys/net/ipv4/tcp_wmem)"
        printf "    %-22s %s\n" "core.rmem_max" "$(cat /proc/sys/net/core/rmem_max)"
        printf "    %-22s %s\n" "core.wmem_max" "$(cat /proc/sys/net/core/wmem_max)"
        printf "    %-22s %s\n" "congestion_ctl" "$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
    ' || true
}

# ── ヘルパ ──
usage() {
    echo "Usage: $0 <script_name.sh> [args...]"
    echo "Example: $0 11_1_pkg_install_check.sh"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

SCRIPT_NAME="$1"
shift

if [ ! -f "${SCRIPT_DIR}/${SCRIPT_NAME}" ]; then
    echo "Error: Script '${SCRIPT_NAME}' not found in ${SCRIPT_DIR}" >&2
    exit 1
fi

# ── Docker イメージのビルド ──
BUILD_OPTS=()
if [ "${NO_CACHE:-0}" = "1" ]; then
    BUILD_OPTS+=(--no-cache)
fi

echo "=== Docker イメージをビルド: ${IMAGE_NAME} ==="
docker build ${BUILD_OPTS[@]+"${BUILD_OPTS[@]}"} -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

# ── TCP バッファ設定 ──
echo "=== コンテナの TCP バッファ設定 ==="
setup_sysctl_opts
show_tcp_settings

# ── コンテナ内でスクリプトを実行 ──
echo "=== ${SCRIPT_NAME} を実行 ==="
docker run --rm \
    ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
    "${IMAGE_NAME}" \
    bash "/opt/routinator-tests/${SCRIPT_NAME}" "$@"
