# Test Certificates

This directory should contain your PKCS#12 certificate files (`.p12` or `.pfx`) for testing X509Certificate2 loading under FIPS mode.

## Setup

1. Place one or more `.p12` or `.pfx` files in this directory
2. Set the `PFX_PASSWORD` environment variable to your certificate password before running tests:

   **Windows:**
   ```powershell
   $env:PFX_PASSWORD = "your-password"
   dotnet run --project tests/FipsValidation
   ```

   **Linux/macOS:**
   ```bash
   export PFX_PASSWORD="your-password"
   dotnet run --project tests/FipsValidation
   ```

   **Docker:**
   ```bash
   docker run -e PFX_PASSWORD="your-password" henryerich/dotnet-aspnet-fips:test
   ```

3. If `PFX_PASSWORD` is not set, an empty password will be used

## Why This Directory Is Excluded

Certificate files are excluded from version control (`.gitignore`) to prevent accidentally committing sensitive credentials. Each user should provide their own test certificates.

## Certificate Requirements

- Must be valid PKCS#12 format (`.p12` or `.pfx`)
- Should contain both certificate and private key
- Password protection is supported via `PFX_PASSWORD` environment variable

The FipsValidation test will load each certificate file and verify that:
- The PKCS#12 container can be parsed using BouncyCastle (bypassing OpenSSL's FIPS restrictions on legacy container formats)
- The certificate and private key are successfully imported into .NET's FIPS-validated crypto layer
- Private key operations work correctly under strict FIPS mode
