// =============================================================================
// FipsValidation — In-process .NET FIPS compliance test
//
// Tests that the .NET runtime correctly uses the OpenSSL FIPS provider:
//   - FIPS-approved algorithms produce valid output
//   - Non-FIPS algorithms throw exceptions
//
// Usage (requires dotnet-sdk-fips or standard .NET SDK to build):
//   docker run --rm -v $(pwd)/tests/FipsValidation:/src -w /src dotnet-sdk-fips dotnet run
// =============================================================================

using System.Security.Cryptography;
using System.Text;

int passed = 0;
int failed = 0;

void Pass(string name, string detail = "")
{
    passed++;
    Console.ForegroundColor = ConsoleColor.Green;
    Console.Write($"  PASS ");
    Console.ResetColor();
    Console.WriteLine($"{name}" + (detail.Length > 0 ? $" — {detail}" : ""));
}

void Fail(string name, string detail = "")
{
    failed++;
    Console.ForegroundColor = ConsoleColor.Red;
    Console.Write($"  FAIL ");
    Console.ResetColor();
    Console.WriteLine($"{name}" + (detail.Length > 0 ? $" — {detail}" : ""));
}

Console.WriteLine("===========================================");
Console.WriteLine("  .NET FIPS Validation Tests");
Console.WriteLine("===========================================");
Console.WriteLine();

byte[] testData = Encoding.UTF8.GetBytes("fips-compliance-test-data");

// ---- FIPS-approved algorithms (should succeed) ----

Console.WriteLine("FIPS-Approved Algorithms (should succeed):");
Console.WriteLine();

// SHA-256
try
{
    using var sha256 = SHA256.Create();
    byte[] hash = sha256.ComputeHash(testData);
    Pass("SHA-256", Convert.ToHexString(hash)[..16] + "...");
}
catch (Exception ex)
{
    Fail("SHA-256", ex.GetType().Name);
}

// SHA-384
try
{
    using var sha384 = SHA384.Create();
    byte[] hash = sha384.ComputeHash(testData);
    Pass("SHA-384", Convert.ToHexString(hash)[..16] + "...");
}
catch (Exception ex)
{
    Fail("SHA-384", ex.GetType().Name);
}

// SHA-512
try
{
    using var sha512 = SHA512.Create();
    byte[] hash = sha512.ComputeHash(testData);
    Pass("SHA-512", Convert.ToHexString(hash)[..16] + "...");
}
catch (Exception ex)
{
    Fail("SHA-512", ex.GetType().Name);
}

// HMAC-SHA256
try
{
    using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes("test-key"));
    byte[] mac = hmac.ComputeHash(testData);
    Pass("HMAC-SHA256", Convert.ToHexString(mac)[..16] + "...");
}
catch (Exception ex)
{
    Fail("HMAC-SHA256", ex.GetType().Name);
}

// AES-256-CBC
try
{
    using var aes = Aes.Create();
    aes.KeySize = 256;
    aes.Mode = CipherMode.CBC;
    aes.GenerateKey();
    aes.GenerateIV();
    using var encryptor = aes.CreateEncryptor();
    byte[] encrypted = encryptor.TransformFinalBlock(testData, 0, testData.Length);
    using var decryptor = aes.CreateDecryptor();
    byte[] decrypted = decryptor.TransformFinalBlock(encrypted, 0, encrypted.Length);
    if (decrypted.SequenceEqual(testData))
        Pass("AES-256-CBC", "encrypt/decrypt round-trip OK");
    else
        Fail("AES-256-CBC", "round-trip mismatch");
}
catch (Exception ex)
{
    Fail("AES-256-CBC", ex.GetType().Name);
}

// RSA 2048
try
{
    using var rsa = RSA.Create(2048);
    byte[] sig = rsa.SignData(testData, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    bool valid = rsa.VerifyData(testData, sig, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    if (valid)
        Pass("RSA-2048 sign/verify", "signature valid");
    else
        Fail("RSA-2048 sign/verify", "signature invalid");
}
catch (Exception ex)
{
    Fail("RSA-2048 sign/verify", ex.GetType().Name);
}

// ECDSA P-256
try
{
    using var ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    byte[] sig = ecdsa.SignData(testData, HashAlgorithmName.SHA256);
    bool valid = ecdsa.VerifyData(testData, sig, HashAlgorithmName.SHA256);
    if (valid)
        Pass("ECDSA P-256 sign/verify", "signature valid");
    else
        Fail("ECDSA P-256 sign/verify", "signature invalid");
}
catch (Exception ex)
{
    Fail("ECDSA P-256 sign/verify", ex.GetType().Name);
}

Console.WriteLine();

// ---- Non-FIPS algorithms (should fail) ----

Console.WriteLine("Non-FIPS Algorithms (should be rejected):");
Console.WriteLine();

// MD5
try
{
    using var md5 = MD5.Create();
    md5.ComputeHash(testData);
    Fail("MD5 rejection", "MD5 was NOT rejected — FIPS may not be active");
}
catch (Exception)
{
    Pass("MD5 rejection", "correctly threw exception");
}

Console.WriteLine();

// ---- Summary ----

Console.WriteLine("===========================================");
Console.Write($"  Results: ");
Console.ForegroundColor = ConsoleColor.Green;
Console.Write($"{passed} passed");
Console.ResetColor();
Console.Write(", ");
if (failed > 0)
    Console.ForegroundColor = ConsoleColor.Red;
Console.Write($"{failed} failed");
Console.ResetColor();
Console.WriteLine($" (out of {passed + failed})");
Console.WriteLine("===========================================");

Environment.Exit(failed > 0 ? 1 : 0);
