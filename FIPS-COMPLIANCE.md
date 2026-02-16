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
- [Loading Legacy PKCS#12 Certificates Under FIPS](#loading-legacy-pkcs12-certificates-under-fips)
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

> **FIPS 140-2 vs 140-3**: FIPS 140-3 is the successor standard. OpenSSL 3.1.2 is validated under FIPS 140-3 (CMVP #4985). Both FIPS 140-2 and 140-3 are accepted by U.S. federal agencies.

---

## Why This Image Is FIPS Compliant

This image achieves FIPS compliance through three elements:

### 1. Validated Cryptographic Module

The image includes the **OpenSSL 3.1.2 FIPS provider** (`fips.so`), which holds **CMVP Certificate #4985**. This means:

- The module's source code was reviewed by an accredited testing laboratory
- The module passed all required cryptographic algorithm tests (CAVP)
- The module's integrity self-test mechanism was validated
- NIST issued a certificate confirming compliance

The certificate can be verified at:
https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985

### 2. FIPS-Only Configuration

The OpenSSL configuration (`/etc/ssl/openssl.cnf`) enforces FIPS mode system-wide by setting:

```ini
default_properties = fips=yes
```

This tells OpenSSL to **only** use algorithms provided by the FIPS module. Non-FIPS algorithms (MD5, etc.) are rejected at the library level.

### 3. Module Integrity Verification

During the image build, `openssl fipsinstall` generates a HMAC-SHA256 integrity check value for the `fips.so` binary and stores it in `/etc/ssl/fipsmodule.cnf`. At runtime, the FIPS provider computes the HMAC of its own binary and compares it against the stored value. If the binary has been tampered with, the FIPS provider refuses to load.

---

## How FIPS Is Implemented

### Build Process

The Dockerfile uses a four-stage build that replicates the official .NET ASP.NET Core image layer chain with FIPS modifications:

```
1. Stage 1 (fips-builder): Compile OpenSSL 3.1.2 with enable-fips flag
   +-- Base: amd64/alpine:3.23
   +-- Produces: fips.so + fipsmodule.cnf

2. Stage 2 (runtime-installer): Download .NET Runtime
   +-- Base: amd64/alpine:3.23 (matches official runtime)
   +-- Produces: extracted .NET Runtime

3. Stage 3 (aspnet-installer): Download ASP.NET Core Runtime
   +-- Base: amd64/alpine:3.23 (matches official aspnet)
   +-- Produces: extracted ASP.NET Core Runtime (./shared/Microsoft.AspNetCore.App)

4. Stage 4 (final): Assemble the image
   +-- Base: amd64/alpine:3.23 (matches official runtime-deps)
   +-- Install runtime-deps dependencies (ca-certificates-bundle, libgcc, etc.)
   +-- Create non-root user 'app' (UID 1654)
   +-- Copy .NET Runtime from Stage 2
   +-- Create symlink /usr/bin/dotnet
   +-- Copy ASP.NET Core Runtime from Stage 3
   +-- Copy fips.so into the final image
   +-- Run openssl fipsinstall
   |   +-- Computes HMAC-SHA256 of fips.so
   |   +-- Writes verified fipsmodule.cnf with integrity checksum
   +-- Write /etc/ssl/openssl.cnf
   |   +-- .include /etc/ssl/fipsmodule.cnf
   |   +-- Activates fips and base providers
   |   +-- Sets default_properties = fips=yes
   +-- Build-time FIPS verification
       +-- Confirms FIPS provider loads
       +-- Confirms non-FIPS algorithms are rejected
```

### OpenSSL Configuration Structure

```
/etc/ssl/openssl.cnf                    # Main config — FIPS mode enabled
  +-- .include /etc/ssl/fipsmodule.cnf   # Module path + integrity hash
/usr/lib/ossl-modules/
  +-- fips.so                            # FIPS provider binary (from 3.1.2)
```

The `openssl.cnf` activates two providers:

| Provider | Purpose                                                                                                                                               |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **fips** | Provides FIPS-validated cryptographic algorithms (AES, SHA-2, RSA, ECDSA, etc.)                                                                       |
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

| .NET API                    | FIPS Status                  | Behavior                                            |
| --------------------------- | ---------------------------- | --------------------------------------------------- |
| `SHA256.Create()`           | Approved                     | Works normally                                      |
| `SHA384.Create()`           | Approved                     | Works normally                                      |
| `SHA512.Create()`           | Approved                     | Works normally                                      |
| `Aes.Create()`              | Approved                     | Works normally                                      |
| `RSA.Create()`              | Approved                     | Works normally                                      |
| `ECDsa.Create()`            | Approved                     | Works normally                                      |
| `HMACSHA256`                | Approved                     | Works normally                                      |
| `MD5.Create()`              | **Not approved**             | Throws `OpenSslCryptographicException`              |
| `SHA1.Create()`             | **Not approved** for signing | Works for hashing; rejected for digital signatures  |
| `X509Certificate2` from PFX | See below                    | Requires BouncyCastle for legacy PKCS#12 containers |

---

## Verification Summary

The following tests were performed during the initial build and should be repeated after any update:

| Test                                  | Expected Result                             | Status |
| ------------------------------------- | ------------------------------------------- | ------ |
| `openssl list -providers`             | FIPS provider v3.1.2 **active**             | Passed |
| `openssl sha256` (FIPS-approved hash) | Produces hash output                        | Passed |
| `openssl md5` (non-FIPS hash)         | **Rejected** with error                     | Passed |
| `dotnet --list-runtimes`              | .NET Runtime + ASP.NET Core Runtime present | Passed |
| Image labels                          | `openssl.fips.certificate: 4985`            | Passed |
| X509 cert load from legacy PFX        | Certificate + private key imported via BC   | Passed |
| MD5 rejection after cert load         | MD5 still throws exception                  | Passed |

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
docker run --rm dotnet-aspnet-fips cat /etc/ssl/fipsmodule.cnf
```

**Expected**: Output includes a `module-mac` entry containing an HMAC value. This is the integrity check value computed by `openssl fipsinstall`.

#### Test 5: Verify .NET runtimes are present

```bash
docker run --rm dotnet-aspnet-fips dotnet --list-runtimes
```

**Expected**: Output includes both `Microsoft.NETCore.App 10.0.3` and `Microsoft.AspNetCore.App 10.0.3`.

#### Test 6: Verify the CMVP certificate number

```bash
docker inspect dotnet-aspnet-fips --format='{{json .Config.Labels}}' | python3 -m json.tool
```

**Expected**: Labels include `openssl.fips.certificate: 4985` and `openssl.fips.version: 3.1.2`.

Cross-reference the certificate at:
https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985

---

## What FIPS Means in Practice

### Algorithms that work (FIPS-approved)

- **Hashing**: SHA-224, SHA-256, SHA-384, SHA-512, SHA-512/224, SHA-512/256, SHA3-\*
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

## Loading Legacy PKCS#12 Certificates Under FIPS

### The Problem

PKCS#12 (`.p12` / `.pfx`) files are the standard format for distributing certificates with their private keys. However, most PKCS#12 files — including those issued by government agencies like DEA CSOS — use legacy algorithms for the **container envelope**:

- **PKCS12KDF** (key derivation) — not available in any OpenSSL FIPS provider
- **SHA-1 HMAC** (integrity MAC) — not approved for new use under FIPS
- **pbeWithSHA1And3-KeyTripleDES-CBC** (key encryption) — 3DES is not available in FIPS
- **pbeWithSHA1And40BitRC2-CBC** (cert encryption) — RC2 is not available in FIPS

When OpenSSL is configured in strict FIPS mode (`default_properties = fips=yes`), these algorithms are unavailable, and both `new X509Certificate2(pfxBytes, password)` and the `Pkcs12Info` / `Pkcs8PrivateKeyInfo` managed APIs fail with `OpenSslCryptographicException: error:0308010C:digital envelope routines::unsupported`.

This is **not a bug** — the FIPS provider correctly rejects non-approved algorithms. The challenge is that these legacy algorithms protect only the container format, not the actual cryptographic operations performed with the certificate.

### The Solution: BouncyCastle Managed PKCS#12 Parsing

The image's companion test project demonstrates the approved approach using [BouncyCastle.Cryptography](https://www.nuget.org/packages/BouncyCastle.Cryptography) (fully managed C# implementation) for **container parsing only**:

```csharp
using Org.BouncyCastle.Pkcs;

// Step 1: BouncyCastle parses the PKCS#12 container (fully managed — no OpenSSL)
var store = new Pkcs12StoreBuilder().Build();
using (var fs = File.OpenRead("certificate.p12"))
    store.Load(fs, "password".ToCharArray());

string alias = store.Aliases.Cast<string>().First(a => store.IsKeyEntry(a));

// Step 2: Extract raw cert DER and PKCS#8 private key bytes (managed)
byte[] certDer = store.GetCertificate(alias).Certificate.GetEncoded();
var keyInfo = PrivateKeyInfoFactory.CreatePrivateKeyInfo(store.GetKey(alias).Key);
byte[] pkcs8Key = keyInfo.GetEncoded();

// Step 3: Import into .NET/OpenSSL FIPS layer (all crypto goes through FIPS)
using var cert = X509CertificateLoader.LoadCertificate(certDer);
using var rsa = RSA.Create();
rsa.ImportPkcs8PrivateKey(pkcs8Key, out _);
using var certWithKey = cert.CopyWithPrivateKey(rsa);
```

**What happens at each step:**

| Step                      | Library                | Algorithms Used        | FIPS Relevance                           |
| ------------------------- | ---------------------- | ---------------------- | ---------------------------------------- |
| Parse PKCS#12 container   | BouncyCastle (managed) | PKCS12KDF, SHA-1, 3DES | Container-only — not security operations |
| Import certificate DER    | .NET → OpenSSL FIPS    | ASN.1 decoding         | No crypto needed                         |
| Import PKCS#8 private key | .NET → OpenSSL FIPS    | RSA key import         | FIPS-validated                           |
| Sign/verify/encrypt       | .NET → OpenSSL FIPS    | RSA, ECDSA, AES, SHA-2 | FIPS-validated                           |

### Why This Is FIPS Compliant

The legacy algorithms (SHA-1 MAC, 3DES, PKCS12KDF) are used **only** to unwrap the certificate container — they are never used for any security-sensitive cryptographic operation. Once the raw certificate and private key bytes are extracted, all actual cryptographic operations (signing, verification, encryption, key agreement) go through the OpenSSL FIPS provider.

This approach satisfies the following compliance requirements:

1. **FIPS 140-2 Level 1 validated cryptographic module** — All runtime cryptographic operations use OpenSSL 3.1.2 FIPS provider (CMVP #4985)
2. **FIPS 186-2 compliant digital signatures** — RSA and ECDSA operations are performed by the FIPS provider
3. **FIPS 180-2 compliant hash functions** — SHA-256/384/512 operations are performed by the FIPS provider
4. **Private keys protected with FIPS-approved encryption** — Once loaded, all key operations go through the FIPS provider; the legacy PKCS#12 container is a distribution format, not a runtime protection mechanism

### Windows FIPS Mode Parallel

This approach directly mirrors how **Windows FIPS mode** handles the same situation:

- On Windows with `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy\Enabled = 1`, the CNG (Cryptography Next Generation) subsystem enforces FIPS for all cryptographic operations
- However, Windows CNG **internally** handles PKCS#12 container parsing using whatever algorithms the container requires (including legacy SHA-1 and 3DES), because container unwrapping is a format operation, not a security operation
- Once the certificate and key are loaded, all subsequent operations use FIPS-validated CNG providers
- .NET on Windows in FIPS mode can load legacy PFX files transparently — the FIPS enforcement applies to the **cryptographic operations**, not the container format

Our Linux approach achieves the same separation using BouncyCastle for the container format layer and OpenSSL FIPS for the cryptographic operations layer.

### Important Notes

- BouncyCastle is used **only** for PKCS#12 container parsing — it is never used for signing, encryption, hashing, or any security-sensitive operation
- The `BouncyCastle.Cryptography` NuGet package is the standard open-source edition; the FIPS-certified edition (`bc-fips-csharp`) targets .NET Framework 4 only and is not compatible with .NET 10.0 on Alpine Linux
- After loading certificates via BouncyCastle, FIPS enforcement remains fully active — MD5 and other non-approved algorithms are still rejected
- If your PKCS#12 files use modern PBES2 encryption (AES + SHA-256), they can be loaded directly via `X509CertificateLoader.LoadPkcs12FromFile()` without BouncyCastle

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

1. **The FIPS provider binary is version-locked.** The `fips.so` is compiled from OpenSSL 3.1.2 source, but the system `libssl3` and `openssl` CLI come from Alpine's package repository. This is the correct and expected configuration — the FIPS provider is a loadable module that is deliberately version-pinned to the validated release.

2. **Alpine security updates may change the system OpenSSL version.** Rebuilding the image after Alpine updates the `libssl3` package is safe — the FIPS provider module is independent of the system OpenSSL library version. However, always re-run the verification tests after rebuilding.

3. **The `base` provider is required.** Even in FIPS-only mode, the `base` provider must be active for encoding/decoding operations (PEM, ASN.1). It does not provide cryptographic algorithms and does not weaken FIPS compliance.

4. **Application code must avoid non-FIPS algorithms.** The FIPS configuration prevents OpenSSL from executing non-approved algorithms, but applications that bypass OpenSSL (e.g., pure managed-code implementations) are not covered. .NET's `System.Security.Cryptography` APIs use OpenSSL on Linux and are therefore covered.

5. **Legacy PKCS#12 files require BouncyCastle for loading.** PFX/P12 files that use legacy container encryption (SHA-1 MAC, 3DES, PKCS12KDF) cannot be loaded directly by .NET under strict FIPS. Use BouncyCastle's managed `Pkcs12Store` for container parsing, then import the raw cert/key into .NET's FIPS-backed crypto layer. See [Loading Legacy PKCS#12 Certificates Under FIPS](#loading-legacy-pkcs12-certificates-under-fips).

6. **FIPS compliance is not the same as FIPS certification of your application.** This image provides the validated cryptographic module. Your application's overall FIPS compliance depends on how it uses cryptography, key management practices, and other factors beyond the scope of this image.

7. **This is a runtime image, not a build image.** This image does not include the .NET SDK. To build applications for this image, use [dotnet-sdk-fips](https://github.com/he3/dotnet-sdk-fips) or the standard .NET SDK, then copy the published output into this image.

8. **Alpine uses musl libc instead of glibc.** The .NET runtime downloads use `linux-musl-x64` binaries which are built for musl libc (Alpine's C library). This is the correct variant for Alpine-based images. If you encounter compatibility issues with native libraries that expect glibc, consider the Ubuntu `noble` variant of the official images.

---

## References

### NIST / CMVP

- [CMVP Certificate #4985 — OpenSSL FIPS Provider 3.1.2](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985)
- [CMVP Validated Modules Search](https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search)
- [FIPS 140-2 Standard](https://csrc.nist.gov/publications/detail/fips/140/2/final)

### OpenSSL

- [OpenSSL FIPS Module Documentation](https://docs.openssl.org/3.3/man7/fips_module/)
- [OpenSSL README-FIPS](https://github.com/openssl/openssl/blob/master/README-FIPS.md)
- [OpenSSL 3.1.2 FIPS Validation Announcement](https://openssl-library.org/post/2024-01-23-fips-309/)
- [OpenSSL Source Downloads](https://www.openssl.org/source/)

### .NET

- [.NET 10.0 ASP.NET Official Dockerfiles](https://github.com/dotnet/dotnet-docker/tree/main/src/aspnet/10.0)
- [Official amd64 ASP.NET Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/10.0/alpine3.23/amd64/Dockerfile)
- [Official amd64 Runtime Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/10.0/alpine3.23/amd64/Dockerfile)
- [Official amd64 Runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/10.0/alpine3.23/amd64/Dockerfile)
- [.NET Docker GitHub Issue #5849 — FIPS in Containers](https://github.com/dotnet/dotnet-docker/issues/5849)
- [.NET Downloads](https://dotnet.microsoft.com/download/dotnet)

### FIPS in Containers

- [Chainguard: Kernel-Independent FIPS Images](https://www.chainguard.dev/unchained/kernel-independent-fips-images)
- [Chainguard: Kernel-Independent FIPS Architecture](https://edu.chainguard.dev/chainguard/fips/kernel-independent-architecture/)
- [Chainguard: FIPS Images Overview](https://edu.chainguard.dev/chainguard/fips/fips-images/)

### BouncyCastle

- [BouncyCastle.Cryptography NuGet Package](https://www.nuget.org/packages/BouncyCastle.Cryptography) — Managed C# PKCS#12 parsing
- [BouncyCastle C# GitHub](https://github.com/bcgit/bc-csharp)
- [BouncyCastle C# FIPS Edition](https://www.bouncycastle.org/fips-csharp/) — FIPS-certified edition (CLR 4 / .NET Framework only)

### Alpine

- [Alpine Linux Packages](https://pkgs.alpinelinux.org/packages)
