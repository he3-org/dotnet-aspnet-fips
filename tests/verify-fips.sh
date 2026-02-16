#!/usr/bin/env bash
# =============================================================================
# verify-fips.sh — Automated FIPS validation test suite for dotnet-aspnet-fips
#
# Usage:
#   ./tests/verify-fips.sh [image-name]
#
# Arguments:
#   image-name  Docker image to test (default: dotnet-aspnet-fips)
#
# Exit code:
#   0  All tests passed
#   1  One or more tests failed
# =============================================================================

set -euo pipefail

# Prevent MSYS/Git Bash on Windows from mangling Linux paths passed to docker
export MSYS_NO_PATHCONV=1

IMAGE="${1:-dotnet-aspnet-fips}"
PASS=0
FAIL=0
TOTAL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

run_test() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    bold "[$TOTAL] $name"
    if "$@"; then
        green "  PASS"
        PASS=$((PASS + 1))
    else
        red "  FAIL"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Pre-flight check
# ---------------------------------------------------------------------------

bold "======================================"
bold "  FIPS Validation Test Suite"
bold "  Image: $IMAGE"
bold "======================================"
echo ""

if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    red "ERROR: Image '$IMAGE' not found. Build it first:"
    red "  docker build -t $IMAGE ."
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: FIPS provider is loaded and active
# ---------------------------------------------------------------------------

test_fips_provider_active() {
    local output
    output=$(docker run --rm "$IMAGE" openssl list -providers 2>&1)
    echo "$output" | grep -q "fips" && echo "$output" | grep -q "active"
}
run_test "FIPS provider is loaded and active" test_fips_provider_active

# ---------------------------------------------------------------------------
# Test 2: FIPS provider version is 3.1.2
# ---------------------------------------------------------------------------

test_fips_provider_version() {
    local output
    output=$(docker run --rm "$IMAGE" openssl list -providers 2>&1)
    echo "$output" | grep -A1 "OpenSSL FIPS Provider" | grep -q "3.1.2"
}
run_test "FIPS provider version is 3.1.2" test_fips_provider_version

# ---------------------------------------------------------------------------
# Test 3: SHA-256 works (FIPS-approved)
# ---------------------------------------------------------------------------

test_sha256_works() {
    docker run --rm "$IMAGE" sh -c "echo -n 'test' | openssl sha256" > /dev/null 2>&1
}
run_test "SHA-256 works (FIPS-approved)" test_sha256_works

# ---------------------------------------------------------------------------
# Test 4: SHA-384 works (FIPS-approved)
# ---------------------------------------------------------------------------

test_sha384_works() {
    docker run --rm "$IMAGE" sh -c "echo -n 'test' | openssl sha384" > /dev/null 2>&1
}
run_test "SHA-384 works (FIPS-approved)" test_sha384_works

# ---------------------------------------------------------------------------
# Test 5: SHA-512 works (FIPS-approved)
# ---------------------------------------------------------------------------

test_sha512_works() {
    docker run --rm "$IMAGE" sh -c "echo -n 'test' | openssl sha512" > /dev/null 2>&1
}
run_test "SHA-512 works (FIPS-approved)" test_sha512_works

# ---------------------------------------------------------------------------
# Test 6: AES-256-CBC encryption works (FIPS-approved)
# ---------------------------------------------------------------------------

test_aes256_works() {
    docker run --rm "$IMAGE" sh -c \
        "echo 'fips-test-data' | openssl enc -aes-256-cbc -pass pass:testkey123 -pbkdf2 | openssl enc -aes-256-cbc -d -pass pass:testkey123 -pbkdf2" > /dev/null 2>&1
}
run_test "AES-256-CBC encryption works (FIPS-approved)" test_aes256_works

# ---------------------------------------------------------------------------
# Test 7: MD5 is rejected (non-FIPS)
# ---------------------------------------------------------------------------

test_md5_rejected() {
    ! docker run --rm "$IMAGE" openssl md5 /dev/null > /dev/null 2>&1
}
run_test "MD5 is rejected (non-FIPS)" test_md5_rejected

# ---------------------------------------------------------------------------
# Test 8: fipsmodule.cnf contains integrity check values
# ---------------------------------------------------------------------------

test_fipsmodule_integrity() {
    local output
    output=$(docker run --rm "$IMAGE" cat /etc/ssl/fipsmodule.cnf 2>&1)
    echo "$output" | grep -q "module-mac"
}
run_test "fipsmodule.cnf contains integrity check values" test_fipsmodule_integrity

# ---------------------------------------------------------------------------
# Test 9: openssl.cnf has fips=yes default properties
# ---------------------------------------------------------------------------

test_openssl_cnf_fips() {
    local output
    output=$(docker run --rm "$IMAGE" cat /etc/ssl/openssl.cnf 2>&1)
    echo "$output" | grep -q "default_properties = fips=yes"
}
run_test "openssl.cnf sets default_properties = fips=yes" test_openssl_cnf_fips

# ---------------------------------------------------------------------------
# Test 10: .NET Runtime is installed
# ---------------------------------------------------------------------------

test_dotnet_runtime() {
    docker run --rm "$IMAGE" dotnet --list-runtimes 2>&1 | grep -q "Microsoft.NETCore.App"
}
run_test ".NET Runtime is installed" test_dotnet_runtime

# ---------------------------------------------------------------------------
# Test 11: ASP.NET Core Runtime is installed
# ---------------------------------------------------------------------------

test_aspnet_runtime() {
    docker run --rm "$IMAGE" dotnet --list-runtimes 2>&1 | grep -q "Microsoft.AspNetCore.App"
}
run_test "ASP.NET Core Runtime is installed" test_aspnet_runtime

# ---------------------------------------------------------------------------
# Test 12: RSA key generation works (FIPS-approved, 2048-bit)
# ---------------------------------------------------------------------------

test_rsa_keygen() {
    docker run --rm "$IMAGE" openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /dev/null 2>&1
}
run_test "RSA 2048-bit key generation works (FIPS-approved)" test_rsa_keygen

# ---------------------------------------------------------------------------
# Test 13: ECDSA key generation works (FIPS-approved, P-256)
# ---------------------------------------------------------------------------

test_ecdsa_keygen() {
    docker run --rm "$IMAGE" openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out /dev/null 2>&1
}
run_test "ECDSA P-256 key generation works (FIPS-approved)" test_ecdsa_keygen

# ---------------------------------------------------------------------------
# Test 14: TLS connection works with FIPS-approved cipher
# ---------------------------------------------------------------------------

test_tls_connection() {
    docker run --rm "$IMAGE" sh -c \
        "echo Q | openssl s_client -connect google.com:443 -brief 2>&1 | grep -qi 'verification.*ok\|tls\|cipher'"
}
run_test "TLS connection succeeds with FIPS-approved ciphers" test_tls_connection

# ---------------------------------------------------------------------------
# Test 15: Image labels are set correctly
# ---------------------------------------------------------------------------

test_image_labels() {
    local labels
    labels=$(docker inspect "$IMAGE" --format='{{json .Config.Labels}}' 2>&1)
    echo "$labels" | grep -q '"openssl.fips.certificate":"4985"' \
        && echo "$labels" | grep -q '"openssl.fips.version":"3.1.2"'
}
run_test "Image labels include FIPS certificate and version" test_image_labels

# ---------------------------------------------------------------------------
# Test 16: Non-root user 'app' exists (matches official runtime-deps)
# ---------------------------------------------------------------------------

test_app_user() {
    docker run --rm "$IMAGE" id app 2>&1 | grep -q "1654"
}
run_test "Non-root user 'app' exists (UID 1654)" test_app_user

# ---------------------------------------------------------------------------
# Test 17: dotnet binary is accessible via symlink
# ---------------------------------------------------------------------------

test_dotnet_symlink() {
    docker run --rm "$IMAGE" sh -c "ls -la /usr/bin/dotnet 2>&1 | grep -q '/usr/share/dotnet/dotnet'"
}
run_test "dotnet binary symlink exists at /usr/bin/dotnet" test_dotnet_symlink

# ---------------------------------------------------------------------------
# Test 18: SDK is NOT installed (this is a runtime-only image)
# ---------------------------------------------------------------------------

test_no_sdk() {
    ! docker run --rm "$IMAGE" dotnet --list-sdks 2>&1 | grep -q "10\."
}
run_test "SDK is NOT installed (runtime-only image)" test_no_sdk

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
bold "======================================"
bold "  Results: $PASS passed, $FAIL failed (out of $TOTAL)"
bold "======================================"

if [ "$FAIL" -gt 0 ]; then
    red "FIPS validation FAILED"
    exit 1
else
    green "All FIPS validation tests PASSED"
    exit 0
fi
