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
#   IMAGE_NAME   – Docker イメージ名 (デフォルト: routinator-test)
#   NO_CACHE     – "1" を指定すると --no-cache でビルド

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${IMAGE_NAME:=routinator-test}"

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

# ── コンテナ内でスクリプトを実行 ──
echo "=== ${SCRIPT_NAME} を実行 ==="
docker run --rm \
    "${IMAGE_NAME}" \
    bash "/opt/routinator-tests/${SCRIPT_NAME}" "$@"
