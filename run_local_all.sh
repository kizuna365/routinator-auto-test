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
# 処理フロー
#   STEP 1: Docker イメージのビルド
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

# ── テスト結果記録 ──
declare -a RESULTS=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ── データ可用性フラグ ──
CACHE_AVAILABLE=false
CSV_AVAILABLE=false

# ── ヘルパー関数 ──
run_test() {
    local name="$1"; shift
    echo "  ▶ Running: ${name}"
    if "$@"; then
        RESULTS+=("PASS: ${name}")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "   PASS: ${name}"
    else
        RESULTS+=("FAIL: ${name}")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "   FAIL: ${name}"
    fi
}

skip_test() {
    local name="$1" reason="$2"
    RESULTS+=("SKIP: ${name} (${reason})")
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo "   SKIP: ${name} (${reason})"
}

run_standalone() {
    local script="$1"
    run_test "${script}" \
        docker run --rm "${IMAGE_NAME}" \
            bash "/opt/routinator-tests/${script}"
}

run_with_cache() {
    local script="$1"
    if "${CACHE_AVAILABLE}"; then
        run_test "${script}" \
            docker run --rm \
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
# STEP 1: Docker イメージのビルド
# ═══════════════════════════════════════════════════════════
echo "[STEP 1] Building Docker image: ${IMAGE_NAME}"
docker build -t "${IMAGE_NAME}" .
echo "[STEP 1] Done"

# ═══════════════════════════════════════════════════════════
# STEP 2: 11_* インストール確認
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 2] 11_* インストール確認"
run_standalone 11_1_pkg_install_check.sh
run_standalone 11_2_version_check.sh
run_standalone 11_3_dependency_check.sh
echo "[STEP 2] Done"

# ═══════════════════════════════════════════════════════════
# STEP 3: 12_* 設定ファイル
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 3] 12_* 設定ファイル"
run_standalone 12_1_default_check.sh
run_standalone 12_2_default_where.sh
run_standalone 12_3_custom_check.sh
echo "[STEP 3] Done"

# ═══════════════════════════════════════════════════════════
# STEP 4: 21_* RPKIデータの取得
#   21_1 + 21_2: rsync/RRDP でデータ取得 → キャッシュ抽出
#   21_3: キャッシュ依存テスト
#   21_4: 単体テスト（データ依存なし）
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 4] 21_* RPKIデータの取得"

# 21_1 + 21_2: 同一コンテナでデータ取得し、キャッシュを抽出
FETCH_CONTAINER="fetch-run-${RUN_ID}"
if docker run --name "${FETCH_CONTAINER}" "${IMAGE_NAME}" bash -c \
    "cd /opt/routinator-tests && bash 21_1_fetch_rsync.sh && bash 21_2_fetch_rrdp.sh"; then
    mkdir -p "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rsync-cache" - | tar xf - -C "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rsync-out" - | tar xf - -C "${CACHE_DIR}"
    docker cp "${FETCH_CONTAINER}:/opt/routinator-tests/routinator-rrdp-out" - | tar xf - -C "${CACHE_DIR}"
    CACHE_AVAILABLE=true
    RESULTS+=("PASS: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh")
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "   PASS: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh"
else
    RESULTS+=("FAIL: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh")
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "   FAIL: 21_1_fetch_rsync.sh + 21_2_fetch_rrdp.sh"
fi
docker rm -f "${FETCH_CONTAINER}" >/dev/null 2>&1 || true

# 21_3: キャッシュ依存
run_with_cache 21_3_check_all_rir.sh

# 21_4: 単体テスト
run_standalone 21_4_timeout_test.sh

echo "[STEP 4] Done"

# ═══════════════════════════════════════════════════════════
# STEP 5: 22_* データ検証
#   22_1: 単体テスト（データ依存なし）
#   22_2〜22_5: キャッシュ依存テスト
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 5] 22_* データ検証"
run_standalone 22_1_check_cert_chain_validation.sh
run_with_cache 22_2_check_roa_signature_validation.sh
run_with_cache 22_3_check_crl_validation.sh
run_with_cache 22_4_check_manifest_validation.sh
run_with_cache 22_5_check_invalid_data_rejection.sh
echo "[STEP 5] Done"

# ═══════════════════════════════════════════════════════════
# STEP 6: 31_* VRP出力形式
#   31_1: CSV生成（キャッシュ依存 → CSV抽出）
#   31_2, 31_3: キャッシュ依存テスト
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 6] 31_* VRP出力形式"

# 31_1: CSV生成（名前付きコンテナで実行し、CSV を抽出）
CSV_CONTAINER="csv-run-${RUN_ID}"
if "${CACHE_AVAILABLE}"; then
    if docker run --name "${CSV_CONTAINER}" \
        -v "${CACHE_DIR}/routinator-rsync-cache:/opt/routinator-tests/routinator-rsync-cache" \
        "${IMAGE_NAME}" \
        bash "/opt/routinator-tests/31_1_output_csv.sh"; then
        mkdir -p "${CSV_DIR}"
        docker cp "${CSV_CONTAINER}:/opt/routinator-tests/routinator-csv-out" - | tar xf - -C "${CSV_DIR}"
        CSV_AVAILABLE=true
        RESULTS+=("PASS: 31_1_output_csv.sh")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "   PASS: 31_1_output_csv.sh"
    else
        RESULTS+=("FAIL: 31_1_output_csv.sh")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "   FAIL: 31_1_output_csv.sh"
    fi
    docker rm -f "${CSV_CONTAINER}" >/dev/null 2>&1 || true
else
    skip_test "31_1_output_csv.sh" "cache not available"
fi

# 31_2, 31_3: キャッシュ依存テスト
run_with_cache 31_2_output_json.sh
run_with_cache 31_3_output_openbgpd.sh

echo "[STEP 6] Done"

# ═══════════════════════════════════════════════════════════
# STEP 7: 32_* VRPデータの正確性
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 7] 32_* VRPデータの正確性"
run_with_csv 32_1_check_prefix.sh
run_with_csv 32_2_check_AS.sh
echo "[STEP 7] Done"

# ═══════════════════════════════════════════════════════════
# STEP 8: 41_* RTRサーバー起動
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 8] 41_* RTRサーバー起動"
run_standalone 41_1_rtr_server_running.sh
run_standalone 41_2_rtr_port_listen.sh
echo "[STEP 8] Done"

# ═══════════════════════════════════════════════════════════
# STEP 9: 42_* RTRプロトコル動作
# ═══════════════════════════════════════════════════════════
echo ""
echo "[STEP 9] 42_* RTRプロトコル動作"
run_server_test 42_1_rtr_client_accept.sh
run_server_test 42_2_rtr_incremental_update.sh
echo "[STEP 9] Done"

# ═══════════════════════════════════════════════════════════
# サマリー
# ═══════════════════════════════════════════════════════════
echo ""
echo "========================================="
echo "  Test Summary"
echo "========================================="
for r in "${RESULTS[@]}"; do
    echo "  ${r}"
done
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
echo "-----------------------------------------"
echo "  PASS: ${PASS_COUNT} / ${TOTAL}"
echo "  FAIL: ${FAIL_COUNT} / ${TOTAL}"
echo "  SKIP: ${SKIP_COUNT} / ${TOTAL}"
echo "========================================="

if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi
