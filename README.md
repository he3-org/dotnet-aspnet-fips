# dotnet-aspnet-fips

A FIPS 140-2 compliant Docker image providing the ASP.NET Core Runtime on Debian, with the OpenSSL FIPS validated cryptographic module. Replicates the full official ASP.NET Core image layer chain (`runtime-deps` -> `runtime` -> `aspnet`) with FIPS modifications applied.

## Current Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Base Image | `amd64/debian:bookworm-slim` | Matches official runtime-deps base |
| FIPS Builder | `debian:bookworm-20260202` | Pinned date-tagged Debian for reproducible FIPS builds |
| Runtime Installer | `amd64/buildpack-deps:bookworm-curl` | Matches official runtime installer stage |
| ASP.NET Installer | `amd64/buildpack-deps:bookworm-curl` | Matches official aspnet installer stage |
| .NET Runtime | 9.0.12 | |
| ASP.NET Core Runtime | 9.0.12 | |
| OpenSSL (system) | 3.0.x | From Debian repos |
| OpenSSL FIPS Provider | 3.0.9 | Built from source; CMVP Certificate #4282 |

## Quick Start

### Build the image

```bash
docker build -t dotnet-aspnet-fips .
```

### Run a container

```bash
docker run --rm -it dotnet-aspnet-fips
```

### Verify FIPS is active

```bash
docker run --rm dotnet-aspnet-fips openssl list -providers
```

Expected output shows the FIPS provider as `active`:

```
Providers:
  base
    name: OpenSSL Base Provider
    version: 3.0.18
    status: active
  fips
    name: OpenSSL FIPS Provider
    version: 3.0.9
    status: active
```

### Run the full test suite

```bash
docker build -t dotnet-aspnet-fips .
./tests/verify-fips.sh
```

See [FIPS-COMPLIANCE.md](FIPS-COMPLIANCE.md) for complete compliance documentation and verification procedures.

---

## How the Image Is Built

The Dockerfile uses a four-stage multi-stage build that replicates the official .NET ASP.NET Core image layer chain (`runtime-deps` -> `runtime` -> `aspnet`) from scratch, with the addition of a FIPS provider build stage:

```
 Stage 1: fips-builder            Stage 2: runtime-installer       Stage 3: aspnet-installer
 (debian:bookworm-20260202)       (amd64/buildpack-deps:           (amd64/buildpack-deps:
 - build-essential                 bookworm-curl)                   bookworm-curl)
 - Downloads OpenSSL 3.0.9       - Downloads .NET Runtime 9.0.12  - Downloads ASP.NET Core 9.0.12
 - ./Configure enable-fips       - Verifies SHA512 checksum       - Verifies SHA512 checksum
 - make && make install_fips     - Extracts full runtime           - Extracts ./shared/
         \                                  |                       Microsoft.AspNetCore.App
          \                                 |                              /
           \                                |                             /
            v                               v                            v
            Stage 4: final image
            (amd64/debian:bookworm-slim)
            ├── runtime-deps layer:
            │   ├── ca-certificates, libc6, libgcc-s1, libicu72,
            │   │   libssl3, libstdc++6, tzdata
            │   └── Non-root user 'app' (UID 1654)
            ├── runtime layer:
            │   ├── COPY .NET Runtime from Stage 2
            │   └── Symlink /usr/bin/dotnet
            ├── aspnet layer:
            │   └── COPY ASP.NET Core Runtime from Stage 3
            ├── FIPS layer:
            │   ├── COPY fips.so + fipsmodule.cnf from Stage 1
            │   ├── openssl fipsinstall (integrity check)
            │   └── FIPS-enabled openssl.cnf
            └── Build-time FIPS verification
```

### Why this structure?

The official ASP.NET Core image is built as a layer chain: `debian:bookworm-slim` -> `runtime-deps` -> `runtime` -> `aspnet`. Since we need to add the FIPS module at the system level, we rebuild the entire chain from `debian:bookworm-slim` so that FIPS is integrated throughout. The final image is equivalent to the official `aspnet` image plus the FIPS provider.

- **Stage 1** compiles the FIPS provider but produces ~800MB of build artifacts. Only `fips.so` (~2MB) and `fipsmodule.cnf` are copied forward.
- **Stage 2** uses `amd64/buildpack-deps:bookworm-curl` (same as the official runtime image) to download and verify the .NET Runtime.
- **Stage 3** uses `amd64/buildpack-deps:bookworm-curl` (same as the official aspnet image) to download and verify the ASP.NET Core Runtime.
- **Stage 4** starts from `amd64/debian:bookworm-slim` (same as the official runtime-deps image) and adds everything.

### Comparison with dotnet-sdk-fips

| | dotnet-aspnet-fips | dotnet-sdk-fips |
|---|---|---|
| **Purpose** | Run ASP.NET Core applications | Build and run .NET applications |
| **Base image** | `amd64/debian:bookworm-slim` | `mcr.microsoft.com/dotnet/aspnet` |
| **Includes SDK** | No | Yes |
| **Includes PowerShell** | No | Yes |
| **Includes ASP.NET Runtime** | Yes | Yes (via aspnet base) |
| **Includes .NET Runtime** | Yes | Yes (via aspnet base) |
| **FIPS module** | Same (OpenSSL 3.0.9) | Same (OpenSSL 3.0.9) |
| **Use case** | Production deployments | CI/CD build environments |

---

## Updating Versions

When a new version of Debian, .NET Runtime, ASP.NET Core, or OpenSSL is released, follow the instructions below. Each section is independent.

### Updating the .NET Runtime / ASP.NET Core Version

The .NET version appears in several places. Always check the official Dockerfiles as the source of truth:
- [runtime-deps](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/9.0/bookworm-slim/amd64/Dockerfile)
- [runtime](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/9.0/bookworm-slim/amd64/Dockerfile)
- [aspnet](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/9.0/bookworm-slim/amd64/Dockerfile)

1. **Find the new version numbers**:
   - Runtime versions: https://dotnet.microsoft.com/download/dotnet
   - Check https://github.com/dotnet/dotnet-docker for exact versions used in official images.

2. **Update the runtime-installer stage** (Stage 2) — change the `dotnet_version` shell variable:
   ```dockerfile
   RUN dotnet_version=<new-runtime-version> \
   ```

3. **Update the aspnet-installer stage** (Stage 3) — change the `aspnetcore_version` shell variable:
   ```dockerfile
   RUN aspnetcore_version=<new-aspnetcore-version> \
   ```

4. **Update the ENV blocks** in Stage 4:
   ```dockerfile
   ENV DOTNET_VERSION=<new-runtime-version>
   ENV ASPNET_VERSION=<new-aspnetcore-version>
   ```

5. **Check the runtime-deps dependencies** — compare against the [official runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/9.0/bookworm-slim/amd64/Dockerfile) for any dependency changes.

6. **For a major version change** (e.g., .NET 9 to .NET 10):
   - Check all three official Dockerfiles for structural changes.
   - The `linux-x64` architecture suffix should remain the same for amd64 builds.

7. **Rebuild and run the test suite**.

### Updating the Debian Base Image

The FIPS builder stage uses a pinned date-tagged Debian image for reproducibility:

```dockerfile
FROM debian:bookworm-20260202 AS fips-builder
```

The final stage uses `amd64/debian:bookworm-slim` (matching official runtime-deps). To update:

1. **Find the latest date-tagged image** at https://hub.docker.com/_/debian/tags?name=bookworm.
2. **Update the fips-builder `FROM` line**:
   ```dockerfile
   FROM debian:bookworm-<new-date> AS fips-builder
   ```
3. **For a new Debian release** (e.g., `trixie` for Debian 13):
   - Wait for Microsoft to publish official runtime images for the new release.
   - Update the `FROM` for fips-builder to use the new release name.
   - Update the installer `FROM` lines to use the matching `amd64/buildpack-deps:<release>-curl`.
   - Update the final `FROM` to use the matching `amd64/debian:<release>-slim`.
   - Check the OpenSSL modules path — verify it hasn't changed:
     ```bash
     docker run --rm debian:<new-release> dpkg -L libssl3 | grep ossl-modules
     ```
   - Check the runtime-deps dependencies — compare against the official Dockerfile for the new release.
4. **Rebuild and run the test suite**.

### Updating the OpenSSL FIPS Provider Version

> **Important**: Only versions listed on the CMVP validated modules list should be used.
> Check https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search
> and search for "OpenSSL" to find currently validated versions and their certificate numbers.

The FIPS provider version is controlled by a single `ARG` in Stage 1:

```dockerfile
ARG OPENSSL_FIPS_VERSION=3.0.9
```

1. **Verify the new version is FIPS-validated** by checking the NIST CMVP database (link above).
2. **Determine the download URL**. OpenSSL archives old releases under `/source/old/<major.minor>/`:
   ```
   https://www.openssl.org/source/old/3.0/openssl-3.0.9.tar.gz
   ```
   If the new version uses a different major.minor (e.g., 3.1.x, 3.4.x), update the URL path in the `curl` command:
   ```dockerfile
   RUN curl -fSL "https://www.openssl.org/source/old/<major.minor>/openssl-${OPENSSL_FIPS_VERSION}.tar.gz" \
   ```
   For the latest release, the URL may be `https://www.openssl.org/source/openssl-<version>.tar.gz` (without `old/`).
3. **Update the ARG**:
   ```dockerfile
   ARG OPENSSL_FIPS_VERSION=<new-version>
   ```
4. **Update the LABEL** in Stage 4 with the new version and CMVP certificate number:
   ```dockerfile
   LABEL ...
         openssl.fips.version="<new-version>" \
         openssl.fips.certificate="<new-cert-number>"
   ```
5. **Check for new build options**. For example, OpenSSL 3.4+ supports `enable-fips-jitter` for userspace entropy (see FIPS-COMPLIANCE.md for details). Review the release notes:
   - https://github.com/openssl/openssl/blob/master/CHANGES.md
   - https://github.com/openssl/openssl/blob/master/README-FIPS.md
6. **Rebuild and run the test suite**.

### Building for arm64 (aarch64) Architecture

To build an arm64 variant, make the following changes:

1. Change the fips-builder `--libdir` from `lib/x86_64-linux-gnu` to `lib/aarch64-linux-gnu`.
2. Change all installer `FROM` lines from `amd64/buildpack-deps:bookworm-curl` to `arm64v8/buildpack-deps:bookworm-curl`.
3. Change the .NET download URL suffixes from `linux-x64` to `linux-arm64`.
4. Change the `OPENSSL_MODULES` ARG path from `x86_64-linux-gnu` to `aarch64-linux-gnu`.
5. Change the final `FROM` from `amd64/debian:bookworm-slim` to `arm64v8/debian:bookworm-slim`.
6. Build on an arm64 host or use `docker buildx`:
   ```bash
   docker buildx build --platform linux/arm64 -t dotnet-aspnet-fips:arm64 .
   ```

---

## Project Structure

```
dotnet-aspnet-fips/
  Dockerfile              # Multi-stage build definition
  .dockerignore           # Files excluded from build context
  README.md               # This file — build instructions and update guide
  FIPS-COMPLIANCE.md      # FIPS compliance documentation and verification
  tests/
    verify-fips.sh        # Automated FIPS validation test script (18 tests)
    FipsValidation/       # .NET console app for in-process FIPS testing
      FipsValidation.csproj
      Program.cs
```

## References

- [.NET 9.0 ASP.NET Official Dockerfiles](https://github.com/dotnet/dotnet-docker/tree/main/src/aspnet/9.0)
- [Official amd64 ASP.NET Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/9.0/bookworm-slim/amd64/Dockerfile)
- [Official amd64 Runtime Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/9.0/bookworm-slim/amd64/Dockerfile)
- [Official amd64 Runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/9.0/bookworm-slim/amd64/Dockerfile)
- [OpenSSL FIPS Module Documentation](https://docs.openssl.org/3.3/man7/fips_module/)
- [OpenSSL README-FIPS](https://github.com/openssl/openssl/blob/master/README-FIPS.md)
- [NIST CMVP Certificate #4282](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4282)
- [Chainguard: Kernel-Independent FIPS Architecture](https://edu.chainguard.dev/chainguard/fips/kernel-independent-architecture/)
- [dotnet-sdk-fips](https://github.com/he3/dotnet-sdk-fips) — Sister project with .NET SDK + FIPS
