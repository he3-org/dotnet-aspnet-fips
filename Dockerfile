# =============================================================================
# dotnet-aspnet-fips
#
# ASP.NET Core 10.0 Runtime on alpine:3.23 with OpenSSL FIPS 140-2
# validated module. The FIPS module is built from OpenSSL 3.1.2
# (CMVP Certificate #4985).
#
# Replicates the official dotnet/dotnet-docker ASP.NET image layer chain:
#   runtime-deps -> runtime -> aspnet
# with FIPS modifications applied.
#
# Official Dockerfiles:
#   runtime-deps: https://github.com/dotnet/dotnet-docker/blob/main/src/runtime-deps/10.0/alpine3.23/amd64/Dockerfile
#   runtime:      https://github.com/dotnet/dotnet-docker/blob/main/src/runtime/10.0/alpine3.23/amd64/Dockerfile
#   aspnet:       https://github.com/dotnet/dotnet-docker/blob/main/src/aspnet/10.0/alpine3.23/amd64/Dockerfile
#
# Architecture: amd64 (x86_64)
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build OpenSSL 3.1.2 FIPS provider module
# ---------------------------------------------------------------------------
FROM amd64/alpine:3.23 AS fips-builder

RUN apk add --no-cache \
        build-base \
        curl \
        linux-headers \
        perl

# OpenSSL 3.1.2 is the FIPS-validated version (CMVP Certificate #4985)
ARG OPENSSL_FIPS_VERSION=3.1.2

RUN curl -fSL "https://www.openssl.org/source/old/3.1/openssl-${OPENSSL_FIPS_VERSION}.tar.gz" \
        -o openssl.tar.gz \
    && tar xzf openssl.tar.gz \
    && cd openssl-${OPENSSL_FIPS_VERSION} \
    && ./Configure enable-fips \
        --prefix=/usr \
        --openssldir=/etc/ssl \
        --libdir=lib \
    && make -j"$(nproc)" \
    && make install_fips

# ---------------------------------------------------------------------------
# Stage 2: Download .NET Runtime
#
# Mirrors the official runtime installer stage.
# Uses Alpine with wget to match the official image pattern.
# ---------------------------------------------------------------------------
FROM amd64/alpine:3.23 AS runtime-installer

RUN apk add --no-cache wget

# Retrieve .NET Runtime
RUN dotnet_version=10.0.3 \
    && wget \
        https://builds.dotnet.microsoft.com/dotnet/Runtime/$dotnet_version/dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz \
        https://builds.dotnet.microsoft.com/dotnet/Runtime/$dotnet_version/dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz.sha512 \
    && sha512sum -c dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz.sha512 \
    && mkdir --parents /dotnet \
    && tar --gzip --extract --no-same-owner --file dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz --directory /dotnet \
    && rm \
        dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz \
        dotnet-runtime-$dotnet_version-linux-musl-x64.tar.gz.sha512

# ---------------------------------------------------------------------------
# Stage 3: Download ASP.NET Core Runtime
#
# Mirrors the official aspnet installer stage.
# ---------------------------------------------------------------------------
FROM amd64/alpine:3.23 AS aspnet-installer

RUN apk add --no-cache wget

# Retrieve ASP.NET Core
RUN aspnetcore_version=10.0.3 \
    && wget \
        https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/$aspnetcore_version/aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz \
        https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/$aspnetcore_version/aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz.sha512 \
    && sha512sum -c aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz.sha512 \
    && mkdir --parents /dotnet \
    && tar --gzip --extract --no-same-owner --file aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz --directory /dotnet ./shared/Microsoft.AspNetCore.App \
    && rm \
        aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz \
        aspnetcore-runtime-$aspnetcore_version-linux-musl-x64.tar.gz.sha512

# ---------------------------------------------------------------------------
# Stage 4: Final image
#
# Built from alpine:3.23 (matching official runtime-deps),
# with .NET Runtime + ASP.NET Core Runtime + FIPS module layered on top.
# ---------------------------------------------------------------------------
FROM amd64/alpine:3.23

# -- Metadata ----------------------------------------------------------------
LABEL maintainer="https://github.com/he3/dotnet-aspnet-fips" \
      description="ASP.NET Core 10.0 Runtime with OpenSSL FIPS 140-2 validated module" \
      org.opencontainers.image.source="https://github.com/he3-org/dotnet-aspnet-fips" \
      openssl.fips.version="3.1.2" \
      openssl.fips.certificate="4985"

# -- runtime-deps environment variables (matches official runtime-deps) ------
ENV \
    # UID of the non-root user 'app'
    APP_UID=1654 \
    # Configure web servers to bind to port 8080 when present
    ASPNETCORE_HTTP_PORTS=8080 \
    # Enable detection of running in a container
    DOTNET_RUNNING_IN_CONTAINER=true \
    # Set the invariant mode since ICU package isn't included (see https://github.com/dotnet/announcements/issues/20)
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true

# -- runtime-deps: Install .NET dependencies (matches official runtime-deps) -
# Note: openssl CLI is added for FIPS configuration (not in official runtime-deps)
RUN apk add --upgrade --no-cache \
        ca-certificates-bundle \
        openssl \
        \
        # .NET dependencies
        libgcc \
        libssl3 \
        libstdc++

# -- runtime-deps: Create non-root user (matches official runtime-deps) ------
RUN addgroup \
        --gid=$APP_UID \
        app \
    && adduser \
        --uid=$APP_UID \
        --ingroup=app \
        --disabled-password \
        app

# -- runtime: .NET Runtime version (matches official runtime) ----------------
ENV DOTNET_VERSION=10.0.3

# -- runtime: Install .NET Runtime (matches official runtime) ----------------
COPY --from=runtime-installer ["/dotnet", "/usr/share/dotnet"]
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet

# -- aspnet: ASP.NET Core version (matches official aspnet) ------------------
ENV ASPNET_VERSION=10.0.3

# -- aspnet: Install ASP.NET Core Runtime (matches official aspnet) ----------
COPY --from=aspnet-installer ["/dotnet", "/usr/share/dotnet"]

# -- Copy FIPS provider module from builder -----------------------------------
ARG OPENSSL_MODULES=/usr/lib/ossl-modules

COPY --from=fips-builder /etc/ssl/fipsmodule.cnf /etc/ssl/fipsmodule.cnf
COPY --from=fips-builder /usr/lib/ossl-modules/fips.so ${OPENSSL_MODULES}/fips.so

# -- Configure OpenSSL for FIPS mode ------------------------------------------
# Generate the fipsmodule.cnf with integrity check values for the installed module
RUN openssl fipsinstall \
        -module ${OPENSSL_MODULES}/fips.so \
        -out /etc/ssl/fipsmodule.cnf

# Write the FIPS-enabled OpenSSL configuration
RUN cp /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf.bak \
    && cat > /etc/ssl/openssl.cnf <<'OPENSSLCNF'
# OpenSSL configuration file — FIPS mode enabled
config_diagnostics = 1
openssl_conf = openssl_init

.include /etc/ssl/fipsmodule.cnf

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

# ---- stock CA / request defaults below (from Alpine) ----

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
