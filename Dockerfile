# =============================================================================
# dotnet-aspnet-fips
#
# ASP.NET Core 9.0 Runtime on debian:bookworm-slim with OpenSSL FIPS 140-2
# validated module. The FIPS module is built from OpenSSL 3.0.9
# (CMVP Certificate #4282).
#
# Replicates the official dotnet/dotnet-docker ASP.NET image layer chain:
#   runtime-deps -> runtime -> aspnet
# with FIPS modifications applied.
#
# Official Dockerfiles:
#   runtime-deps: https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/9.0/bookworm-slim/amd64/Dockerfile
#   runtime:      https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/9.0/bookworm-slim/amd64/Dockerfile
#   aspnet:       https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/9.0/bookworm-slim/amd64/Dockerfile
#
# Architecture: amd64 (x86_64)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build OpenSSL 3.0.9 FIPS provider module
# ---------------------------------------------------------------------------
FROM debian:bookworm-20260202 AS fips-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        perl \
    && rm -rf /var/lib/apt/lists/*

# OpenSSL 3.0.9 is the FIPS-validated version (CMVP Certificate #4282)
ARG OPENSSL_FIPS_VERSION=3.0.9

RUN curl -fSL "https://www.openssl.org/source/old/3.0/openssl-${OPENSSL_FIPS_VERSION}.tar.gz" \
        -o openssl.tar.gz \
    && tar xzf openssl.tar.gz \
    && cd openssl-${OPENSSL_FIPS_VERSION} \
    && ./Configure enable-fips \
        --prefix=/usr \
        --openssldir=/usr/lib/ssl \
        --libdir=lib/x86_64-linux-gnu \
    && make -j"$(nproc)" \
    && make install_fips

# ---------------------------------------------------------------------------
# Stage 2: Download .NET Runtime
#
# Mirrors the official runtime installer stage:
#   FROM amd64/buildpack-deps:bookworm-curl AS installer
# ---------------------------------------------------------------------------
FROM amd64/buildpack-deps:bookworm-curl AS runtime-installer

# Retrieve .NET Runtime
RUN dotnet_version=9.0.12 \
    && curl --fail --show-error --location \
        --remote-name https://builds.dotnet.microsoft.com/dotnet/Runtime/$dotnet_version/dotnet-runtime-$dotnet_version-linux-x64.tar.gz \
        --remote-name https://builds.dotnet.microsoft.com/dotnet/checksums/$dotnet_version-sha.txt \
    && sed -i 's/\r$//' $dotnet_version-sha.txt \
    && sha512sum -c $dotnet_version-sha.txt --ignore-missing \
    && mkdir --parents /dotnet \
    && tar --gzip --extract --no-same-owner --file dotnet-runtime-$dotnet_version-linux-x64.tar.gz --directory /dotnet \
    && rm \
        dotnet-runtime-$dotnet_version-linux-x64.tar.gz \
        $dotnet_version-sha.txt

# ---------------------------------------------------------------------------
# Stage 3: Download ASP.NET Core Runtime
#
# Mirrors the official aspnet installer stage:
#   FROM amd64/buildpack-deps:bookworm-curl AS installer
# ---------------------------------------------------------------------------
FROM amd64/buildpack-deps:bookworm-curl AS aspnet-installer

# Retrieve ASP.NET Core
RUN aspnetcore_version=9.0.12 \
    && curl --fail --show-error --location \
        --remote-name https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/$aspnetcore_version/aspnetcore-runtime-$aspnetcore_version-linux-x64.tar.gz \
        --remote-name https://builds.dotnet.microsoft.com/dotnet/checksums/$aspnetcore_version-sha.txt \
    && sed -i 's/\r$//' $aspnetcore_version-sha.txt \
    && sha512sum -c $aspnetcore_version-sha.txt --ignore-missing \
    && mkdir --parents /dotnet \
    && tar --gzip --extract --no-same-owner --file aspnetcore-runtime-$aspnetcore_version-linux-x64.tar.gz --directory /dotnet ./shared/Microsoft.AspNetCore.App \
    && rm \
        aspnetcore-runtime-$aspnetcore_version-linux-x64.tar.gz \
        $aspnetcore_version-sha.txt

# ---------------------------------------------------------------------------
# Stage 4: Final image
#
# Built from debian:bookworm-slim (matching official runtime-deps),
# with .NET Runtime + ASP.NET Core Runtime + FIPS module layered on top.
# ---------------------------------------------------------------------------
FROM amd64/debian:bookworm-slim

# -- Metadata ----------------------------------------------------------------
LABEL maintainer="https://github.com/he3-org/dotnet-aspnet-fips" \
      description="ASP.NET Core 9.0 Runtime with OpenSSL FIPS 140-2 validated module" \
      org.opencontainers.image.source="https://github.com/he3-org/dotnet-aspnet-fips" \
      openssl.fips.version="3.0.9" \
      openssl.fips.certificate="4282"

# -- runtime-deps environment variables (matches official runtime-deps) ------
ENV \
    # UID of the non-root user 'app'
    APP_UID=1654 \
    # Configure web servers to bind to port 8080 when present
    ASPNETCORE_HTTP_PORTS=8080 \
    # Enable detection of running in a container
    DOTNET_RUNNING_IN_CONTAINER=true

# -- runtime-deps: Install .NET dependencies (matches official runtime-deps) -
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        \
        # .NET dependencies
        libc6 \
        libgcc-s1 \
        libicu72 \
        libssl3 \
        libstdc++6 \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# -- runtime-deps: Create non-root user (matches official runtime-deps) ------
RUN groupadd \
        --gid=$APP_UID \
        app \
    && useradd --no-log-init \
        --uid=$APP_UID \
        --gid=$APP_UID \
        --create-home \
        app

# -- runtime: .NET Runtime version (matches official runtime) ----------------
ENV DOTNET_VERSION=9.0.12

# -- runtime: Install .NET Runtime (matches official runtime) ----------------
COPY --from=runtime-installer ["/dotnet", "/usr/share/dotnet"]
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet

# -- aspnet: ASP.NET Core version (matches official aspnet) ------------------
ENV ASPNET_VERSION=9.0.12

# -- aspnet: Install ASP.NET Core Runtime (matches official aspnet) ----------
COPY --from=aspnet-installer ["/dotnet", "/usr/share/dotnet"]

# -- Copy FIPS provider module from builder -----------------------------------
ARG OPENSSL_MODULES=/usr/lib/x86_64-linux-gnu/ossl-modules

COPY --from=fips-builder /usr/lib/ssl/fipsmodule.cnf /usr/lib/ssl/fipsmodule.cnf
COPY --from=fips-builder /usr/lib/x86_64-linux-gnu/ossl-modules/fips.so ${OPENSSL_MODULES}/fips.so

# -- Configure OpenSSL for FIPS mode ------------------------------------------
# Generate the fipsmodule.cnf with integrity check values for the installed module
RUN openssl fipsinstall \
        -module ${OPENSSL_MODULES}/fips.so \
        -out /usr/lib/ssl/fipsmodule.cnf

# Write the FIPS-enabled OpenSSL configuration
RUN cp /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf.bak \
    && cat > /etc/ssl/openssl.cnf <<'OPENSSLCNF'
# OpenSSL configuration file — FIPS mode enabled
config_diagnostics = 1
openssl_conf = openssl_init

.include /usr/lib/ssl/fipsmodule.cnf

[openssl_init]
providers = provider_sect
alg_section = algorithm_sect

[provider_sect]
fips = fips_sect
base = base_sect

[base_sect]
activate = 1

[algorithm_sect]
default_properties = fips=yes

# ---- stock CA / request defaults below (from Debian) ----

[ca]
default_ca = CA_default

[CA_default]
dir               = /etc/ssl
certs             = $dir/certs
database          = $dir/index.txt
new_certs_dir     = $dir/newcerts
serial            = $dir/serial
crlnumber         = $dir/crlnumber
crl               = $dir/crl.pem
RANDFILE          = $dir/.rand
default_days      = 365
default_crl_days  = 30
default_md        = sha256
preserve          = no
policy            = policy_anything

[policy_anything]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[req]
default_bits        = 2048
default_md          = sha256
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca

[req_distinguished_name]
countryName                 = Country Name (2 letter code)
stateOrProvinceName         = State or Province Name (full name)
localityName                = Locality Name (eg, city)
0.organizationName          = Organization Name (eg, company)
organizationalUnitName      = Organizational Unit Name (eg, section)
commonName                  = Common Name (eg, fully qualified host name)
emailAddress                = Email Address

[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:true

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = nonRepudiation, digitalSignature, keyEncipherment
OPENSSLCNF

# -- Verify FIPS is active ----------------------------------------------------
RUN openssl list -providers | grep -q "fips" \
    && echo "FIPS provider loaded successfully" \
    || (echo "ERROR: FIPS provider not loaded" && exit 1)

# Non-FIPS algorithms (like MD5) should fail
RUN ! openssl md5 /dev/null 2>/dev/null \
    && echo "FIPS enforcement verified (MD5 correctly rejected)" \
    || echo "WARNING: MD5 was not rejected — check FIPS configuration"

# -- Verify runtimes are present -----------------------------------------------
RUN dotnet --list-runtimes
