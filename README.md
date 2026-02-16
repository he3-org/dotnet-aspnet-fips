# dotnet-aspnet-fips

A FIPS 140-2 compliant Docker image providing the ASP.NET Core Runtime on Alpine Linux, with the OpenSSL FIPS validated cryptographic module. Replicates the full official ASP.NET Core image layer chain (`runtime-deps` -> `runtime` -> `aspnet`) with FIPS modifications applied.

## Current Versions

| Component             | Version             | Notes                                             |
| --------------------- | ------------------- | ------------------------------------------------- |
| Base Image            | `amd64/alpine:3.23` | Matches official runtime-deps base                |
| FIPS Builder          | `amd64/alpine:3.23` | Same Alpine version for consistent OpenSSL builds |
| .NET Runtime          | 10.0.3              |                                                   |
| ASP.NET Core Runtime  | 10.0.3              |                                                   |
| OpenSSL (system)      | 3.x                 | From Alpine repos                                 |
| OpenSSL FIPS Provider | 3.1.2               | Built from source; CMVP Certificate #4985         |

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
    version: 3.x.x
    status: active
  fips
    name: OpenSSL FIPS Provider
    version: 3.1.2
    status: active
```

### Run the full test suite

```bash
docker build -t dotnet-aspnet-fips .
./tests/verify-fips.sh
```

See [FIPS-COMPLIANCE.md](FIPS-COMPLIANCE.md) for complete compliance documentation and verification procedures.

---

## Deployment

### Azure App Service

For detailed instructions on deploying this image to Azure App Service on Linux with FIPS mode enabled, see [AZURE-DEPLOYMENT.md](AZURE-DEPLOYMENT.md).

Quick start:

```bash
# Build and push
docker build -t your-username/dotnet-aspnet-fips:latest .
docker push your-username/dotnet-aspnet-fips:latest

# Deploy to Azure
az group create --name rg-myapp --location eastus
az appservice plan create --name plan-myapp --resource-group rg-myapp --is-linux --sku B1
az webapp create --name myapp --resource-group rg-myapp --plan plan-myapp \
  --deployment-container-image-name your-username/dotnet-aspnet-fips:latest

# Enable FIPS mode
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
az resource update \
  --ids /subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-myapp/providers/Microsoft.Web/sites/myapp \
  --set properties.siteConfig.linuxFipsModeEnabled=true
```

---

## How the Image Is Built

The Dockerfile uses a four-stage multi-stage build that replicates the official .NET ASP.NET Core image layer chain (`runtime-deps` -> `runtime` -> `aspnet`) from scratch, with the addition of a FIPS provider build stage:

```
 Stage 1: fips-builder            Stage 2: runtime-installer       Stage 3: aspnet-installer
 (amd64/alpine:3.23)              (amd64/alpine:3.23)              (amd64/alpine:3.23)
 - build-base, curl, perl        - Downloads .NET Runtime 10.0.3  - Downloads ASP.NET Core 10.0.3
 - Downloads OpenSSL 3.1.2         (linux-musl-x64)                 (linux-musl-x64)
 - ./Configure enable-fips       - Verifies SHA512 checksum       - Verifies SHA512 checksum
 - make && make install_fips     - Extracts full runtime           - Extracts ./shared/
         \                                  |                       Microsoft.AspNetCore.App
          \                                 |                              /
           \                                |                             /
            v                               v                            v
            Stage 4: final image
            (amd64/alpine:3.23)
            +-- runtime-deps layer:
            |   +-- ca-certificates-bundle, libgcc, libssl3, libstdc++
            |   +-- Non-root user 'app' (UID 1654)
            +-- runtime layer:
            |   +-- COPY .NET Runtime from Stage 2
            |   +-- Symlink /usr/bin/dotnet
            +-- aspnet layer:
            |   +-- COPY ASP.NET Core Runtime from Stage 3
            +-- FIPS layer:
            |   +-- COPY fips.so + fipsmodule.cnf from Stage 1
            |   +-- openssl fipsinstall (integrity check)
            |   +-- FIPS-enabled openssl.cnf
            +-- Build-time FIPS verification
```

### Why this structure?

The official ASP.NET Core image is built as a layer chain: `alpine:3.23` -> `runtime-deps` -> `runtime` -> `aspnet`. Since we need to add the FIPS module at the system level, we rebuild the entire chain from `alpine:3.23` so that FIPS is integrated throughout. The final image is equivalent to the official `aspnet` image plus the FIPS provider.

- **Stage 1** compiles the FIPS provider but produces large build artifacts. Only `fips.so` (~2MB) and `fipsmodule.cnf` are copied forward.
- **Stage 2** uses `amd64/alpine:3.23` with `wget` (matching the official runtime image pattern) to download and verify the .NET Runtime.
- **Stage 3** uses `amd64/alpine:3.23` with `wget` (matching the official aspnet image pattern) to download and verify the ASP.NET Core Runtime.
- **Stage 4** starts from `amd64/alpine:3.23` (same as the official runtime-deps image) and adds everything.

### Comparison with dotnet-sdk-fips

|                              | dotnet-aspnet-fips            | dotnet-sdk-fips                   |
| ---------------------------- | ----------------------------- | --------------------------------- |
| **Purpose**                  | Run ASP.NET Core applications | Build and run .NET applications   |
| **Base image**               | `amd64/alpine:3.23`           | `mcr.microsoft.com/dotnet/aspnet` |
| **Includes SDK**             | No                            | Yes                               |
| **Includes PowerShell**      | No                            | Yes                               |
| **Includes ASP.NET Runtime** | Yes                           | Yes (via aspnet base)             |
| **Includes .NET Runtime**    | Yes                           | Yes (via aspnet base)             |
| **FIPS module**              | Same (OpenSSL 3.1.2)          | Same (OpenSSL 3.1.2)              |
| **Use case**                 | Production deployments        | CI/CD build environments          |

---

## Updating Versions

When a new version of Alpine, .NET Runtime, ASP.NET Core, or OpenSSL is released, follow the instructions below. Each section is independent.

### Updating the .NET Runtime / ASP.NET Core Version

The .NET version appears in several places. Always check the official Dockerfiles as the source of truth:

- [runtime-deps](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/10.0/alpine3.23/amd64/Dockerfile)
- [runtime](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/10.0/alpine3.23/amd64/Dockerfile)
- [aspnet](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/10.0/alpine3.23/amd64/Dockerfile)

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

5. **Check the runtime-deps dependencies** — compare against the [official runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/10.0/alpine3.23/amd64/Dockerfile) for any dependency changes.

6. **For a major version change** (e.g., .NET 10 to .NET 11):
    - Check all three official Dockerfiles for structural changes.
    - The `linux-musl-x64` architecture suffix should remain the same for Alpine amd64 builds.

7. **Rebuild and run the test suite**.

### Updating the Alpine Base Image

All stages use the same Alpine version for consistency:

```dockerfile
FROM amd64/alpine:3.23 AS fips-builder
FROM amd64/alpine:3.23 AS runtime-installer
FROM amd64/alpine:3.23 AS aspnet-installer
FROM amd64/alpine:3.23
```

To update:

1. **Find the latest Alpine version** at https://hub.docker.com/_/alpine/tags.
2. **Update all `FROM` lines** to the new Alpine version.
3. **For a new Alpine major release**:
    - Wait for Microsoft to publish official runtime images for the new release.
    - Update the `FROM` lines to use the new version.
    - Check the OpenSSL modules path — verify it hasn't changed:
        ```bash
        docker run --rm alpine:<new-version> ls /usr/lib/ossl-modules/ 2>/dev/null || echo "Path changed"
        ```
    - Check the runtime-deps dependencies — compare against the official Dockerfile for the new release.
4. **Rebuild and run the test suite**.

### Updating the OpenSSL FIPS Provider Version

> **Important**: Only versions listed on the CMVP validated modules list should be used.
> Check https://csrc.nist.gov/projects/cryptographic-module-validation-program/validated-modules/search
> and search for "OpenSSL" to find currently validated versions and their certificate numbers.

The FIPS provider version is controlled by a single `ARG` in Stage 1:

```dockerfile
ARG OPENSSL_FIPS_VERSION=3.1.2
```

1. **Verify the new version is FIPS-validated** by checking the NIST CMVP database (link above).
2. **Determine the download URL**. OpenSSL archives old releases under `/source/old/<major.minor>/`:
    ```
    https://www.openssl.org/source/old/3.1/openssl-3.1.2.tar.gz
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

1. Change all `FROM amd64/alpine:3.23` to `FROM arm64v8/alpine:3.23`.
2. Change the .NET download URL suffixes from `linux-musl-x64` to `linux-musl-arm64`.
3. Build on an arm64 host or use `docker buildx`:
    ```bash
    docker buildx build --platform linux/arm64 -t dotnet-aspnet-fips:arm64 .
    ```

---

## Project Structure

```
dotnet-aspnet-fips/
  Dockerfile              # Multi-stage build definition
  Dockerfile.test         # Test container with FipsValidation app bundled
  .dockerignore           # Files excluded from build context
  README.md               # This file — build instructions and update guide
  FIPS-COMPLIANCE.md      # FIPS compliance documentation and verification
  AZURE-DEPLOYMENT.md     # Azure App Service deployment guide
  tests/
    verify-fips.sh        # Automated FIPS validation test script (18 tests)
    FipsValidation/       # .NET console app for in-process FIPS testing
      FipsValidation.csproj
      Program.cs
      test-certs/         # Your .p12/.pfx certificate files for testing
        README.md         # Certificate setup instructions
```

## Running In-Process .NET Tests

The `FipsValidation` project contains 11 .NET tests that verify FIPS compliance from within a .NET application. These tests include X509Certificate2 loading from PKCS#12 files.

### Prerequisites

If testing certificate loading, place your `.p12` or `.pfx` files in `tests/FipsValidation/test-certs/` and configure the password:

**Option 1: .env file (recommended)**

Create `tests/FipsValidation/.env`:

```bash
PFX_PASSWORD=your-certificate-password
```

**Option 2: Environment variable**

```bash
export PFX_PASSWORD="your-certificate-password"
```

### Run Tests Locally

```bash
cd tests/FipsValidation
dotnet run
```

### Run Tests in Docker

```bash
# Build the FIPS runtime image
docker build -t dotnet-aspnet-fips .

# Build test container (includes FipsValidation app)
docker build -f Dockerfile.test -t dotnet-aspnet-fips:test .

# Run tests with certificate password
docker run --rm -e PFX_PASSWORD="your-password" dotnet-aspnet-fips:test
```

See `tests/FipsValidation/test-certs/README.md` for detailed certificate setup instructions.

## Azure Container Instance Note

You may have to set an environment variable

```bash
export NODE_OPTIONS=--openssl-legacy-provider
```

## References

- [.NET 10.0 ASP.NET Official Dockerfiles](https://github.com/dotnet/dotnet-docker/tree/main/src/aspnet/10.0)
- [Official amd64 ASP.NET Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/10.0/alpine3.23/amd64/Dockerfile)
- [Official amd64 Runtime Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/10.0/alpine3.23/amd64/Dockerfile)
- [Official amd64 Runtime-deps Dockerfile](https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/10.0/alpine3.23/amd64/Dockerfile)
- [OpenSSL FIPS Module Documentation](https://docs.openssl.org/3.3/man7/fips_module/)
- [OpenSSL README-FIPS](https://github.com/openssl/openssl/blob/master/README-FIPS.md)
- [NIST CMVP Certificate #4985](https://csrc.nist.gov/projects/cryptographic-module-validation-program/certificate/4985)
- [Chainguard: Kernel-Independent FIPS Architecture](https://edu.chainguard.dev/chainguard/fips/kernel-independent-architecture/)
- [dotnet-sdk-fips](https://github.com/he3/dotnet-sdk-fips) — Sister project with .NET SDK + FIPS
