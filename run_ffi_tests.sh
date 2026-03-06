#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${SCRIPT_DIR}/../nebula_core"
BUILD_DIR="${CORE_DIR}/build_crypto_test"
TDLIB_DIR="${CORE_DIR}/external/tdlib/lib"

echo "Setting up environment for Dart FFI tests..."
export LD_LIBRARY_PATH="${BUILD_DIR}/lib:${TDLIB_DIR}:${LD_LIBRARY_PATH}"

echo "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"

cd "${SCRIPT_DIR}"
flutter test test/cipher_engine_test.dart
