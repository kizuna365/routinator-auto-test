#!/usr/bin/env bash
# run_local_all.sh – ローカル環境で routinator-self-test.yml と同等のテストを実行する
#
# 使い方:
#   ./run_local_all.sh
#
# 実行環境:
#   - Linux (Ubuntu 22.04 相当)
#   - Docker 利用可能
#   - インターネット接続あり
#
# 環境変数:
#   TCP_RMEM  – コンテナ内の net.ipv4.tcp_rmem (デフォルト: "4096 87380 16777216")
#   TCP_WMEM  – コンテナ内の net.ipv4.tcp_wmem (デフォルト: "4096 65536 16777216")
#   TCP_CC    – 輻輳制御アルゴリズム (例: bbr。未指定ならカーネル既定のまま)
#   NO_SYSCTL – "1" を指定すると sysctl 調整を一切行わない
#
# 処理フロー
#   STEP 1: Docker イメージのビルド / TCP バッファ設定の決定
#   STEP 2: 11_* インストール確認
#   STEP 3: 12_* 設定ファイル
#   STEP 4: 21_* RPKIデータの取得
#   STEP 5: 22_* データ検証
#   STEP 6: 31_* VRP出力形式
#   STEP 7: 32_* VRPデータの正確性
#   STEP 8: 41_* RTRサーバー起動
#   STEP 9: 42_* RTRプロトコル動作

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

IMAGE_NAME="routinator-test"
RUN_ID="1"
CACHE_DIR="${SCRIPT_DIR}/.rpki-local-cache-${RUN_ID}"
CSV_DIR="${SCRIPT_DIR}/.rpki-local-csv-${RUN_ID}"

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
    printf '    %-22s %s\n' "tcp_rmem"       "$(cat /proc/sys/net/ipv4/tcp_rmem 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "tcp_wmem"       "$(cat /proc/sys/net/ipv4/tcp_wmem 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "core.rmem_max"  "$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo N/A)"
    printf '    %-22s %s\n' "core.wmem_max"  "$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo N/A)"
    echo "  --- container ---"
    docker run --rm ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} "${IMAGE_NAME}" bash -c '
        printf "    %-22s %s\n" "tcp_rmem"       "$(cat /proc/sys/net/ipv4/tcp_rmem)"
        printf "    %-22s %s\n" "tcp_wmem"       "$(cat /proc/sys/net/ipv4/tcp_wmem)"
        printf "    %-22s %s\n" "core.rmem_max"  "$(cat /proc/sys/net/core/rmem_max)"
        printf "    %-22s %s\n" "core.wmem_max"  "$(cat /proc/sys/net/core/wmem_max)"
        printf "    %-22s %s\n" "congestion_ctl" "$(cat /proc/sys/net/ipv4/tcp_congestion_control)"
    ' || true
}

# ── テスト結果記録 ──
declare -a RESULTS=()
declare -a DURATIONS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SCRIPT_START=$(date +%s)

# ── データ可用性フラグ ──
CACHE_AVAILABLE=false
CSV_AVAILABLE=false

# ── ヘルパー関数 ──
format_duration() {
    local total_sec=$1
    if [ "${total_sec}" -ge 3600 ]; then
        printf '%dh %dm %ds' $((total_sec/3600)) $((total_sec%3600/60)) $((total_sec%60))
    elif [ "${total_sec}" -ge 60 ]; then
        printf '%dm %ds' $((total_sec/60)) $((total_sec%60))
    else
        printf '%ds' "${total_sec}"
    fi
}

run_test() {
    local name="$1"; shift
    echo "  ▶ Running: ${name}"
    local t_start; t_start=$(date +%s)
    if "$@"; then
        local t_end; t_end=$(date +%s)
        local dur=$((t_end - t_start))
        RESULTS+=("PASS: ${name}")
        DURATIONS+=("${dur}")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS: ${name} ($(format_duration ${dur}))"
    else
        local t_end; t_end=$(date +%s)
        local dur=$((t_end - t_start))
        RESULTS+=("FAIL: ${name}")
        DURATIONS+=("${dur}")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL: ${name} ($(format_duration ${dur}))"
    fi
}

skip_test() {
    local name="$1" reason="$2"
    RESULTS+=("SKIP: ${name} (${reason})")
    DURATIONS+=("0")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "  SKIP: ${name} (${reason})"
}

run_standalone() {
    local script="$1"
    run_test "${script}" \
        docker run --rm \
            ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
            "${IMAGE_NAME}" \
            bash "/opt/routinator-tests/${script}"
}

run_with_cache() {
    local script="$1"
    if "${CACHE_AVAILABLE}"; then
        run_test "${script}" \
            docker run --rm \
                ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
                -v "${CACHE_DIR}/routinator-rsync-cache:/opt/routinator-tests/routinator-rsync-cache" \
                -v "${CACHE_DIR}/routinator-rsync-out:/opt/routinator-tests/routinator-rsync-out" \
                -v "${CACHE_DIR}/routinator-rrdp-out:/opt/routinator-tests/routinator-rrdp-out" \
                "${IMAGE_NAME}" \
                bash "/opt/routinator-tests/${script}"
    else
        skip_test "${script}" "cache not available"
    fi
}

run_with_csv() {
    local script="$1"
    if "${CSV_AVAILABLE}"; then
        run_test "${script}" \
            docker run --rm \
                ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
                -v "${CSV_DIR}/routinator-csv-out:/opt/routinator-tests/routinator-csv-out" \
                "${IMAGE_NAME}" \
                bash "/opt/routinator-tests/${script}"
    else
        skip_test "${script}" "CSV not available"
    fi
}

run_server_test() {
    local script="$1"
    if "${CACHE_AVAILABLE}"; then
        run_test "${script}" \
            docker run --rm \
                ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
                -v "${CACHE_DIR}/routinator-rsync-cache:/opt/routinator-tests/routinator-rsync-cache" \
                -e REPOSITORY_DIR=/opt/routinator-tests/routinator-rsync-cache \
                "${IMAGE_NAME}" \
                bash -c "cd /opt/routinator-tests && bash ${script}"
    else
        skip_test "${script}" "cache not available"
    fi
}

cleanup() {
    echo ""
    echo "[CLEANUP] Removing temporary directories..."
    rm -rf "${CACHE_DIR}" "${CSV_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════
# STEP 1: Docker イメージのビルド / TCP バッファ設定の決定
# ═══════════════════════════════════════════════════════════
echo "[STEP 1] Building Docker image: ${IMAGE_NAME}"
STEP1_START=$(date +%s)
docker build -t "${IMAGE_NAME}" .

echo "[STEP 1] Configuring container TCP buffers"
setup_sysctl_opts
show_tcp_settings

STEP1_END=$(date +%s)
echo "[STEP 1] Done ($(format_duration $((STEP1_END - STEP1_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 2: 11_* インストール確認
# ═══════════════════════════════════════════════════════════
echo ""
STEP2_START=$(date +%s)
echo "[STEP 2] 11_* インストール確認"
run_standalone 11_1_pkg_install_check.sh
run_standalone 11_2_version_check.sh
run_standalone 11_3_dependency_check.sh
STEP2_END=$(date +%s)
echo "[STEP 2] Done ($(format_duration $((STEP2_END - STEP2_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 3: 12_* 設定ファイル
# ═══════════════════════════════════════════════════════════
echo ""
STEP3_START=$(date +%s)
echo "[STEP 3] 12_* 設定ファイル"
run_standalone 12_1_default_check.sh
run_standalone 12_2_default_where.sh
run_standalone 12_3_custom_check.sh
STEP3_END=$(date +%s)
echo "[STEP 3] Done ($(format_duration $((STEP3_END - STEP3_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 4: 21_* RPKIデータの取得
#   21_1 + 21_2: rsync/RRDP でデータ取得 → キャッシュ抽出
#   21_3: キャッシュ依存テスト
#   21_4: 単体テスト（データ依存なし）
# ═══════════════════════════════════════════════════════════
echo ""
STEP4_START=$(date +%s)
echo "[STEP 4] 21_* RPKIデータの取得"

# 21_1 + 21_2: 同一コンテナでデータ取得し、キャッシュを抽出
FETCH_CONTAINER="fetch-run-${RUN_ID}"
echo "  ▶ Running: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh"
FETCH_START=$(date +%s)
if docker run --name "${FETCH_CONTAINER}" \
        ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
        "${IMAGE_NAME}" bash -c \
        "cd /opt/routinator-tests && bash 21_1_fetch_rsync.sh && bash 21_2_fetch_rrdp.sh"; then
    mkdir -p "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rsync-cache" - | tar xf - -C "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rsync-out" - | tar xf - -C "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rrdp-out" - | tar xf - -C "${CACHE_DIR}"
    FETCH_END=$(date +%s)
    FETCH_DUR=$((FETCH_END - FETCH_START))
    CACHE_AVAILABLE=true
    RESULTS+=("PASS: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh")
    DURATIONS+=("${FETCH_DUR}")
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh ($(format_duration ${FETCH_DUR}))"
else
    FETCH_END=$(date +%s)
    FETCH_DUR=$((FETCH_END - FETCH_START))
    RESULTS+=("FAIL: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh")
    DURATIONS+=("${FETCH_DUR}")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh ($(format_duration ${FETCH_DUR}))"
fi
docker rm -f "${FETCH_CONTAINER}" >/dev/null 2>&1 || true

# 21_3: キャッシュ依存
run_with_cache 21_3_check_all_rir.sh

# 21_4: 単体テスト
run_standalone 21_4_timeout_test.sh
STEP4_END=$(date +%s)
echo "[STEP 4] Done ($(format_duration $((STEP4_END - STEP4_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 5: 22_* データ検証
#   22_1: 単体テスト（データ依存なし）
#   22_2〜22_5: キャッシュ依存テスト
# ═══════════════════════════════════════════════════════════
echo ""
STEP5_START=$(date +%s)
echo "[STEP 5] 22_* データ検証"
run_standalone 22_1_check_cert_chain_validation.sh
run_with_cache 22_2_check_roa_signature_validation.sh
run_with_cache 22_3_check_crl_validation.sh
run_with_cache 22_4_check_manifest_validation.sh
run_with_cache 22_5_check_invalid_data_rejection.sh
STEP5_END=$(date +%s)
echo "[STEP 5] Done ($(format_duration $((STEP5_END - STEP5_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 6: 31_* VRP出力形式
#   31_1: CSV生成（キャッシュ依存 → CSV抽出）
#   31_2, 31_3: キャッシュ依存テスト
# ═══════════════════════════════════════════════════════════
echo ""
STEP6_START=$(date +%s)
echo "[STEP 6] 31_* VRP出力形式"

# 31_1: CSV生成（名前付きコンテナで実行し、CSV を抽出）
CSV_CONTAINER="csv-run-${RUN_ID}"
if "${CACHE_AVAILABLE}"; then
    echo "  ▶ Running: 31_1_output_csv.sh"
    CSV_T_START=$(date +%s)
    if docker run --name "${CSV_CONTAINER}" \
            ${SYSCTL_OPTS[@]+"${SYSCTL_OPTS[@]}"} \
            -v "${CACHE_DIR}/routinator-rsync-cache:/opt/routinator-tests/routinator-rsync-cache" \
            "${IMAGE_NAME}" \
            bash "/opt/routinator-tests/31_1_output_csv.sh"; then
        mkdir -p "${CSV_DIR}"
        docker cp "${CSV_CONTAINER}:/opt/routinator-tests/routinator-csv-out" - | tar xf - -C "${CSV_DIR}"
        CSV_T_END=$(date +%s)
        CSV_DUR=$((CSV_T_END - CSV_T_START))
        CSV_AVAILABLE=true
        RESULTS+=("PASS: 31_1_output_csv.sh")
        DURATIONS+=("${CSV_DUR}")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  PASS: 31_1_output_csv.sh ($(format_duration ${CSV_DUR}))"
    else
        CSV_T_END=$(date +%s)
        CSV_DUR=$((CSV_T_END - CSV_T_START))
        RESULTS+=("FAIL: 31_1_output_csv.sh")
        DURATIONS+=("${CSV_DUR}")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  FAIL: 31_1_output_csv.sh ($(format_duration ${CSV_DUR}))"
    fi
    docker rm -f "${CSV_CONTAINER}" >/dev/null 2>&1 || true
else
    skip_test "31_1_output_csv.sh" "cache not available"
fi

# 31_2, 31_3: キャッシュ依存テスト
run_with_cache 31_2_output_json.sh
run_with_cache 31_3_output_openbgpd.sh
STEP6_END=$(date +%s)
echo "[STEP 6] Done ($(format_duration $((STEP6_END - STEP6_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 7: 32_* VRPデータの正確性
# ═══════════════════════════════════════════════════════════
echo ""
STEP7_START=$(date +%s)
echo "[STEP 7] 32_* VRPデータの正確性"
run_with_csv 32_1_check_prefix.sh
run_with_csv 32_2_check_AS.sh
STEP7_END=$(date +%s)
echo "[STEP 7] Done ($(format_duration $((STEP7_END - STEP7_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 8: 41_* RTRサーバー起動
# ═══════════════════════════════════════════════════════════
echo ""
STEP8_START=$(date +%s)
echo "[STEP 8] 41_* RTRサーバー起動"
run_standalone 41_1_rtr_server_running.sh
run_standalone 41_2_rtr_port_listen.sh
STEP8_END=$(date +%s)
echo "[STEP 8] Done ($(format_duration $((STEP8_END - STEP8_START))))"

# ═══════════════════════════════════════════════════════════
# STEP 9: 42_* RTRプロトコル動作
# ═══════════════════════════════════════════════════════════
echo ""
STEP9_START=$(date +%s)
echo "[STEP 9] 42_* RTRプロトコル動作"
run_server_test 42_1_rtr_client_accept.sh
run_server_test 42_2_rtr_incremental_update.sh
STEP9_END=$(date +%s)
echo "[STEP 9] Done ($(format_duration $((STEP9_END - STEP9_START))))"

# ═══════════════════════════════════════════════════════════
# サマリー
# ═══════════════════════════════════════════════════════════
SCRIPT_END=$(date +%s)
TOTAL_DUR=$((SCRIPT_END - SCRIPT_START))

echo ""
echo "========================================="
echo "  Test Summary"
echo "========================================="
for i in "${!RESULTS[@]}"; do
    printf '  %-55s %s\n' "${RESULTS[$i]}" "$(format_duration ${DURATIONS[$i]})"
done
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo "-----------------------------------------"
echo "  PASS: ${PASS_COUNT} / ${TOTAL}"
echo "  FAIL: ${FAIL_COUNT} / ${TOTAL}"
echo "  SKIP: ${SKIP_COUNT} / ${TOTAL}"
echo "-----------------------------------------"
echo "  Total time: $(format_duration ${TOTAL_DUR})"
echo "========================================="

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
