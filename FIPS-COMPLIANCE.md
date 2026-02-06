# FIPS 140-2 Compliance Documentation

This document explains how and why the `dotnet-aspnet-fips` Docker image is FIPS compliant, and how to verify that compliance.

---

## Table of Contents

- [What Is FIPS 140-2?](#what-is-fips-140-2)
- [Why This Image Is FIPS Compliant](#why-this-image-is-fips-compliant)
- [How FIPS Is Implemented](#how-fips-is-implemented)
- [How .NET Uses FIPS](#how-net-uses-fips)
- [Verification Summary](#verification-summary)
- [How to Validate and Verify FIPS](#how-to-validate-and-verify-fips)
- [What FIPS Means in Practice](#what-fips-means-in-practice)
- [Kernel-Independent FIPS](#kernel-independent-fips)
- [Limitations and Considerations](#limitations-and-considerations)
- [References](#references)

---

## What Is FIPS 140-2?

FIPS 140-2 (Federal Information Processing Standard Publication 140-2) is a U.S. government standard that defines minimum security requirements for cryptographic modules. It is required for:

- Federal agencies and contractors handling sensitive data
- Healthcare organizations subject to HIPAA
- Financial institutions with regulatory requirements
- Any organization whose compliance framework mandates FIPS

The standard is administered by NIST through the Cryptographic Module Validation Program (CMVP). A cryptographic module must pass laboratory testing and receive a CMVP certificate number to be considered "FIPS validated."

> **FIPS 140-2 vs 140-3**: FIPS 140-3 is the successor standard. OpenSSL 3.0.9 is validated under FIPS 140-2. Future OpenSSL versions may target 140-3. Both are accepted by U.S. federal agencies.

---

## Why This Image Is FIPS Compliant

This image achieves FIPS compliance through three elements:

### 1. Validated Cryptographic Module

The image includes the **OpenSSL 3.0.9 FIPS provider** (`fips.so`), which holds **CMVP Certificate #4282**. This means:

- The module's source code was reviewed by an accredited testing laboratory
- The module passed all required cryptographic algorithm tests (CAVP)
- The module's integrity self-test mechanism was validated
- NIST issued a certificate confirming compliance

The certificate can be verified at:
https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4282

### 2. FIPS-Only Configuration

The OpenSSL configuration (`/etc/ssl/openssl.cnf`) enforces FIPS mode system-wide by setting:

```ini
default_properties = fips=yes
```

This tells OpenSSL to **only** use algorithms provided by the FIPS module. Non-FIPS algorithms (MD5, etc.) are rejected at the library level.

### 3. Module Integrity Verification

During the image build, `openssl fipsinstall` generates a HMAC-SHA256 integrity check value for the `fips.so` binary and stores it in `/usr/lib/ssl/fipsmodule.cnf`. At runtime, the FIPS provider computes the HMAC of its own binary and compares it against the stored value. If the binary has been tampered with, the FIPS provider refuses to load.

---

## How FIPS Is Implemented

### Build Process

The Dockerfile uses a four-stage build that replicates the official .NET ASP.NET Core image layer chain with FIPS modifications:

```
1. Stage 1 (fips-builder): Compile OpenSSL 3.0.9 with enable-fips flag
   ├── Base: debian:bookworm-20260202 (pinned for reproducibility)
   └── Produces: fips.so + fipsmodule.cnf

2. Stage 2 (runtime-installer): Download .NET Runtime
   ├── Base: amd64/buildpack-deps:bookworm-curl (matches official runtime)
   └── Produces: extracted .NET Runtime

3. Stage 3 (aspnet-installer): Download ASP.NET Core Runtime
   ├── Base: amd64/buildpack-deps:bookworm-curl (matches official aspnet)
   └── Produces: extracted ASP.NET Core Runtime (./shared/Microsoft.AspNetCore.App)

4. Stage 4 (final): Assemble the image
   ├── Base: amd64/debian:bookworm-slim (matches official runtime-deps)
   ├── Install runtime-deps dependencies (ca-certificates, libc6, etc.)
   ├── Create non-root user 'app' (UID 1654)
   ├── Copy .NET Runtime from Stage 2
   ├── Create symlink /usr/bin/dotnet
   ├── Copy ASP.NET Core Runtime from Stage 3
   ├── Copy fips.so into the final image
   ├── Run openssl fipsinstall
   │   └── Computes HMAC-SHA256 of fips.so
   │   └── Writes verified fipsmodule.cnf with integrity checksum
   ├── Write /etc/ssl/openssl.cnf
   │   └── .include /usr/lib/ssl/fipsmodule.cnf
   │   └── Activates fips and base providers
   │   └── Sets default_properties = fips=yes
   └── Build-time FIPS verification
       └── Confirms FIPS provider loads
       └── Confirms non-FIPS algorithms are rejected
```

### OpenSSL Configuration Structure

```
/etc/ssl/openssl.cnf                    # Main config — FIPS mode enabled
  └── .include /usr/lib/ssl/fipsmodule.cnf  # Module path + integrity hash
/usr/lib/x86_64-linux-gnu/ossl-modules/
  └── fips.so                            # FIPS provider binary (from 3.0.9)
```

The `openssl.cnf` activates two providers:

| Provider | Purpose |
|----------|---------|
| **fips** | Provides FIPS-validated cryptographic algorithms (AES, SHA-2, RSA, ECDSA, etc.) |
| **base** | Provides non-cryptographic operations (encoding, decoding, serialization). Required for basic OpenSSL functionality. Does not provide any algorithms. |

The `default` provider (which includes non-validated algorithms like MD5) is intentionally **not** activated.

---

## How .NET Uses FIPS

.NET on Linux delegates all cryptographic operations to OpenSSL via P/Invoke calls to `libssl` and `libcrypto`. It does **not** bundle its own cryptographic implementations. This means:

- When OpenSSL is configured for FIPS mode, .NET automatically operates in FIPS mode
- No .NET-specific configuration is required
- FIPS-approved algorithms (SHA-256, AES, RSA, ECDSA) work normally
- Non-FIPS algorithms (MD5) throw `OpenSslCryptographicException` at runtime

### .NET Crypto API Behavior Under FIPS

| .NET API | FIPS Status | Behavior |
|----------|-------------|----------|
| `SHA256.Create()` | Approved | Works normally |
| `SHA384.Create()` | Approved | Works normally |
| `SHA512.Create()` | Approved | Works normally |
| `Aes.Create()` | Approved | Works normally |
| `RSA.Create()` | Approved | Works normally |
| `ECDsa.Create()` | Approved | Works normally |
| `HMACSHA256` | Approved | Works normally |
| `MD5.Create()` | **Not approved** | Throws `OpenSslCryptographicException` |
| `SHA1.Create()` | **Not approved** for signing | Works for hashing; rejected for digital signatures |

---

## Verification Summary

The following tests were performed during the initial build and should be repeated after any update:

| Test | Expected Result | Status |
|------|-----------------|--------|
| `openssl list -providers` | FIPS provider v3.0.9 **active** | Passed |
| `openssl sha256` (FIPS-approved hash) | Produces hash output | Passed |
| `openssl md5` (non-FIPS hash) | **Rejected** with error | Passed |
| `dotnet --list-runtimes` | .NET Runtime + ASP.NET Core Runtime present | Passed |
| Image labels | `openssl.fips.certificate: 4282` | Passed |

---

## How to Validate and Verify FIPS

### Automated Test Suite

Run the full verification script:

```bash
./tests/verify-fips.sh
```

This script performs all of the tests described below automatically and reports pass/fail.

### Manual Verification Steps

#### Test 1: Verify the FIPS provider is loaded

```bash
docker run --rm dotnet-aspnet-fips openssl list -providers
```

**Expected**: Output includes a `fips` provider entry with `status: active`.

#### Test 2: Verify FIPS-approved algorithms work

```bash
docker run --rm dotnet-aspnet-fips sh -c "echo -n 'test' | openssl sha256"
```

**Expected**: Outputs a SHA-256 hash without errors.

#### Test 3: Verify non-FIPS algorithms are rejected

```bash
docker run --rm dotnet-aspnet-fips openssl md5 /dev/null
```

**Expected**: Fails with an error containing `unsupported` and/or `initialization error`. The exit code should be non-zero.

#### Test 4: Verify the FIPS module integrity check value exists

```bash
docker run --rm dotnet-aspnet-fips cat /usr/lib/ssl/fipsmodule.cnf
```

**Expected**: Output includes `module-mac` and `install-mac` entries containing HMAC values. These are the integrity check values computed by `openssl fipsinstall`.

#### Test 5: Verify .NET runtimes are present

```bash
docker run --rm dotnet-aspnet-fips dotnet --list-runtimes
```

**Expected**: Output includes both `Microsoft.NETCore.App 9.0.12` and `Microsoft.AspNetCore.App 9.0.12`.

#### Test 6: Verify the CMVP certificate number

```bash
docker inspect dotnet-aspnet-fips --format='{{json .Config.Labels}}' | python3 -m json.tool
```

**Expected**: Labels include `openssl.fips.certificate: 4282` and `openssl.fips.version: 3.0.9`.

Cross-reference the certificate at:
https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4282

---

## What FIPS Means in Practice

### Algorithms that work (FIPS-approved)

- **Hashing**: SHA-224, SHA-256, SHA-384, SHA-512, SHA-512/224, SHA-512/256, SHA3-*
- **Symmetric encryption**: AES (128, 192, 256) in CBC, GCM, CCM, CTR, XTS, and WRAP modes
- **Asymmetric encryption**: RSA (2048+ bits)
- **Digital signatures**: RSA, ECDSA, EdDSA (Ed25519, Ed448)
- **Key agreement**: ECDH, DH (2048+ bits)
- **Message authentication**: HMAC-SHA2, CMAC, GMAC
- **Key derivation**: HKDF, SSKDF, KBKDF, TLS 1.3 KDF

### Algorithms that are blocked (not FIPS-approved)

- **MD5**: Rejected entirely
- **DES / 3DES**: Legacy encryption — not available
- **RC4**: Stream cipher — not available
- **Blowfish**: Not available
- **IDEA**: Not available
- **RSA < 2048 bits**: Key sizes below 2048 bits are rejected
- **DSA**: Legacy signature algorithm — not available in FIPS provider

### TLS implications

When FIPS mode is active, only TLS cipher suites using FIPS-approved algorithms are available. In practice, this means TLS 1.2 with AES-GCM or AES-CBC cipher suites, and TLS 1.3 (which uses only FIPS-approved algorithms by default). Legacy cipher suites using RC4 or 3DES are unavailable.

---

## Kernel-Independent FIPS

Traditional FIPS deployments required the host Linux kernel to be running in FIPS mode (`fips=1` boot parameter). This created challenges for containerized workloads because:

- Container images cannot control host kernel settings
- Many cloud providers do not enable kernel FIPS mode by default
- Kernel FIPS mode enforcement varies across distributions

This image uses a **kernel-independent** approach:

- The OpenSSL FIPS provider enforces FIPS at the **userspace level**
- The `fipsmodule.cnf` integrity check and `openssl.cnf` configuration enforce FIPS without any kernel support
- The image works identically on FIPS-enabled and non-FIPS hosts
- No host configuration is required

This approach follows the pattern documented by Chainguard for kernel-independent FIPS images.

### Future: Jitter Entropy

OpenSSL 3.4+ supports `enable-fips-jitter`, which uses a userspace entropy source (Jitter Entropy Library) instead of `/dev/urandom`. This further strengthens the kernel-independent model by removing the dependency on kernel-provided entropy. The Jitter Entropy Library has its own NIST SP 800-90B Entropy Source Validation.

When upgrading the FIPS provider to OpenSSL 3.4+, consider using:

```
./Configure enable-fips enable-fips-jitter
```

Note that this requires the new version to also be CMVP-validated. Check the NIST CMVP database before upgrading.

---

## Limitations and Considerations

1. **The FIPS provider binary is version-locked.** The `fips.so` is compiled from OpenSSL 3.0.9 source, but the system `libssl3` and `openssl` CLI come from Debian's package repository (currently 3.0.18). This is the correct and expected configuration — the FIPS provider is a loadable module that is deliberately version-pinned to the validated release.

2. **Debian security updates may change the system OpenSSL version.** Rebuilding the image after Debian updates the `libssl3` package is safe — the FIPS provider module is independent of the system OpenSSL library version. However, always re-run the verification tests after rebuilding.

3. **The `base` provider is required.** Even in FIPS-only mode, the `base` provider must be active for encoding/decoding operations (PEM, ASN.1). It does not provide cryptographic algorithms and does not weaken FIPS compliance.

4. **Application code must avoid non-FIPS algorithms.** The FIPS configuration prevents OpenSSL from executing non-approved algorithms, but applications that bypass OpenSSL (e.g., pure managed-code implementations) are not covered. .NET's `System.Security.Cryptography` APIs use OpenSSL on Linux and are therefore covered.

5. **FIPS compliance is not the same as FIPS certification of your application.** This image provides the validated cryptographic module. Your application's overall FIPS compliance depends on how it uses cryptography, key management practices, and other factors beyond the scope of this image.

6. **This is a runtime image, not a build image.** This image does not include the .NET SDK. To build applications for this image, use [dotnet-sdk-fips](https://github.com/he3/dotnet-sdk-fips) or the standard .NET SDK, then copy the published output into this image.

---

## References

### NIST / CMVP
- [CMVP Certificate #4282 — OpenSSL FIPS Provider 3.0.9](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4282)
- [CMVP Validated Modules Search](https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search)
- [FIPS 140-2 Standard](https://csrc.nist.gov/publications/detail/fips/140/2/final)

### OpenSSL
- [OpenSSL FIPS Module Documentation](https://docs.openssl.org/3.3/man7/fips_module/)
- [OpenSSL README-FIPS](https://github.com/openssl/openssl/blob/master/README-FIPS.md)
- [OpenSSL 3.0.9 FIPS Validation Announcement](https://openssl-library.org/post/2024-01-23-fips-309/)
- [OpenSSL Source Downloads](https://www.openssl.org/source/)

### .NET
- [.NET 9.0 ASP.NET Official Dockerfiles](https://github.com/dotnet/dotnet-docker/tree/main/src/aspnet/9.0)
- [Official amd64 ASP.NET Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/9.0/bookworm-slim/amd64/Dockerfile)
- [Official amd64 Runtime Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/9.0/bookworm-slim/amd64/Dockerfile)
- [Official amd64 Runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/9.0/bookworm-slim/amd64/Dockerfile)
- [.NET Docker GitHub Issue #5849 — FIPS in Containers](https://github.com/dotnet/dotnet-docker/issues/5849)
- [.NET Downloads](https://dotnet.microsoft.com/download/dotnet)

### FIPS in Containers
- [Chainguard: Kernel-Independent FIPS Images](https://www.chainguard.dev/unchained/kernel-independent-fips-images)
- [Chainguard: Kernel-Independent FIPS Architecture](https://edu.chainguard.dev/chainguard/fips/kernel-independent-architecture/)
- [Chainguard: FIPS Images Overview](https://edu.chainguard.dev/chainguard/fips/fips-images/)

### Sister Project
- [dotnet-sdk-fips](https://github.com/he3/dotnet-sdk-fips) — .NET SDK with FIPS (for building applications)

### Debian
- [Add FIPS Module to OpenSSL 3.0.11 on Debian 12 Bookworm (aikchar.dev)](https://aikchar.dev/blog/add-fips-module-to-openssl-3011-on-debian-12-bookworm.html)
