# PS.SSL

[![validate](https://github.com/jjohns-dev/PS.SSL/actions/workflows/ci.yml/badge.svg)](https://github.com/jjohns-dev/PS.SSL/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/jjohns-dev/PS.SSL?display_name=tag&sort=semver)](https://github.com/jjohns-dev/PS.SSL/releases)
[![License](https://img.shields.io/github/license/jjohns-dev/PS.SSL)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)

PowerShell module that wraps `openssl` for creating and inspecting SSL/TLS
certificates, certificate signing requests (CSRs), private keys, PFX bundles,
and for probing the cipher and protocol support of remote endpoints.

Requires PowerShell 7.0+ and `openssl` on `PATH`.

## Prerequisites

This module requires Openssl.
To install Openssl on Windows using winget, use the code below.

```pwsh
winget install --Id ShiningLight.OpenSSL

# OR (smaller footprint)
winget install --Id ShiningLight.OpenSSL.Light
```

To install Openssl on mac OS using Homebrew, use the code below.

```sh
brew install openssl@3
```

To install Openssl on Debian-based Linux, use the follow code.

```sh
# UPDATE PACKAGE LIST
sudo apt update

# INSTALL OPENSSL
sudo apt install openssl -y
```

## Installation

This module is not yet published to the PowerShell Gallery. Install from
source:

```pwsh
# Clone into your user modules folder
$modulesPath = ($env:PSModulePath -split [System.IO.Path]::PathSeparator)[0]
git clone https://github.com/jjohns-dev/PS.SSL.git (Join-Path $modulesPath 'PS.SSL')

# Import
Import-Module PS.SSL
```

The `examples/setup.ps1` helper does the same end-to-end on Windows,
macOS, and Linux (installs openssl via winget/brew/apt-get/dnf, clones
into your user-scope modules folder, and copies the example scripts to
`~/ps.ssl-examples`). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the local development workflow
(psake build, Pester tests, PSScriptAnalyzer).

## Cmdlets

| Cmdlet | Purpose |
|---|---|
| **CSR, key, and certificate generation** | |
| `New-CertificateSigningRequest` (alias `New-CSR`) | Generate a CSR and matching private key. Renders an openssl `req` config from parameters or accepts a caller-supplied config file. |
| `New-SelfSignedCertificate` | Generate a self-signed certificate, private key, and config in one shot. |
| `Get-CSRTemplate` | Return the canonical `openssl req` config template as `[string[]]`. Useful as a starting point for hand-crafted configs. |
| **Inspection and parsing** | |
| `Get-CertificateData` | Parse a `.pem` certificate into a `[System.Security.Cryptography.X509Certificates.X509Certificate2]` object via openssl-normalized DER bytes. |
| `Get-CSRData` | Parse a `.csr` file into a structured object (`Subject`, `PublicKeyAlgorithm`, `PublicKeyBits`, `SignatureAlgorithm`, `SubjectAlternativeName`, `Verified`, plus the full openssl text in `Raw`). |
| `Get-RemoteSSLCertificate` | Retrieve the leaf certificate served by a remote host (HTTPS or any TLS-enabled service). |
| `ConvertFrom-PKCS7` | Extract the certificates inside a PKCS#7 (`.p7b`) bundle. |
| `ConvertTo-PEM` | Normalize certificate content to PEM (`-----BEGIN CERTIFICATE-----`) format. |
| **Export and packaging** | |
| `Export-Base64Certificate` | Write a byte array as a PEM-formatted `.crt` file (RFC 7468, 64-char line width). |
| `Export-CertificateData` | Extract the certificate, intermediate chain, or private key block out of a combined `.pem` bundle into separate files. |
| `Export-PFX` | Bundle a certificate plus private key into a PFX (`.pfx`) file. Passwords are handed to openssl via the child-process environment, not the command line. |
| **Verification** | |
| `Test-PrivateKeyCertMatch` | Confirm that a private key matches a certificate by comparing the SHA-256 hashes of their public keys. |
| **Remote server probing** (openssl `s_client` under the hood) | |
| `Test-Cipher` | Test whether a remote host accepts a specific cipher suite. |
| `Test-Protocol` | Test whether a remote host supports a specific TLS/SSL protocol version. |
| `Test-SSLProtocol` | Higher-level scan: enumerate the protocol versions a remote host supports. |

Run `Get-Help <Cmdlet-Name> -Full` for parameter details and examples on any
of the above.

Every cmdlet carries a `Status` marker (`Stable`, `Beta`, `Experimental`, or
`Deprecated`) in its `.NOTES` block. Most exports are `Stable`; three are
currently `Beta` and may change shape based on feedback:
`Export-CertificateData`, `Get-CertificateData`, `Get-CSRData`. Run
`Get-Help <Cmdlet-Name> -Full` to see the marker for any cmdlet.

## Usage

### Generate a CSR and private key

```pwsh
$csrParams = @{
    CommonName             = 'www.example.com'
    Organization           = 'Example Inc'
    Country                = 'US'
    State                  = 'WA'
    Locality               = 'Seattle'
    SubjectAlternativeName = 'example.com', 'api.example.com'
    OutputDirectory        = 'C:\certs'
}
New-CertificateSigningRequest @csrParams
```

Writes three files into `C:\certs`:

- `www.example.com.csr` &mdash; the certificate signing request
- `www.example.com_PRIVATE.key` &mdash; the matching RSA private key (unencrypted)
- `www.example.com.conf` &mdash; the openssl config used, preserved as a reproducible record

### Retrieve and inspect a remote certificate

```pwsh
$cert = Get-RemoteSSLCertificate -ComputerName 'github.com'

$cert | Select-Object Subject, Issuer, NotBefore, NotAfter, Thumbprint
$cert.DnsNameList

# Save a copy as a base64-encoded .crt
Export-Base64Certificate -ByteArray $cert.RawData -Path "$HOME\github.com.crt"
```

### Bundle a certificate and key into a PFX

```pwsh
$password = Read-Host -AsSecureString -Prompt 'PFX password'

$pfxParams = @{
    KeyPath         = '.\www.example.com_PRIVATE.key'
    SignedCSRPath   = '.\www.example.com.crt'
    RootCAPath      = '.\root-ca.crt'
    OutputDirectory = 'C:\certs'
    Password        = $password
}
Export-PFX @pfxParams
```

Writes `C:\certs\www.example.com.pfx` (the basename is derived from
`-SignedCSRPath`). The password is delivered to `openssl pkcs12` via a
per-child-process environment variable (`-passout env:VAR`) rather than the
command line, so it never appears in process listings, EDR telemetry, or
audit logs.

### Probe a remote server's TLS support

```pwsh
Test-SSLProtocol -ComputerName 'example.com'
```

Returns a table showing which TLS protocol versions the host accepts. For
finer-grained probes use `Test-Protocol` (one version at a time) or
`Test-Cipher` (a specific cipher suite).

## Updates

Please see release information for updates.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
