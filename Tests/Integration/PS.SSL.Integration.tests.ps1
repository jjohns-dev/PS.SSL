BeforeDiscovery {
    # Gate the entire Describe on openssl availability so CI runners that
    # lack openssl skip cleanly rather than failing. Use a script-scoped
    # variable so it survives Discovery -> Run transitions.
    $script:HasOpenSsl = [bool] (Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    # See New-CertificateSigningRequest.tests.ps1 for rationale: `-Force` does
    # not displace a module loaded from a different absolute path, so remove
    # all existing PS.SSL copies before importing to keep the session clean.
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force
}

Describe 'PS.SSL integration (real openssl)' -Tag 'Integration' -Skip:(-not $script:HasOpenSsl) {

    Context 'New-CertificateSigningRequest end-to-end' {

        It 'Produces a CSR and matching private key that openssl can verify' {
            $cn  = 'integration.example.com'
            $dir = Join-Path $TestDrive 'csr'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            New-CertificateSigningRequest -CommonName $cn -OutputDirectory $dir -KeySize 2048 -Confirm:$false

            $csrPath = Join-Path $dir "$cn.csr"
            $keyPath = Join-Path $dir "${cn}_PRIVATE.key"

            Test-Path -Path $csrPath -PathType Leaf | Should -BeTrue
            Test-Path -Path $keyPath -PathType Leaf | Should -BeTrue

            # `openssl req -verify` self-checks the CSR signature against its
            # embedded public key - the strongest single-shot proof that the
            # generated CSR is well-formed and internally consistent.
            $null = & openssl req -in $csrPath -noout -verify 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context 'Test-PrivateKeyCertMatch' {

        BeforeAll {
            $script:cnA  = 'match-a.example.com'
            $script:cnB  = 'match-b.example.com'
            $script:dir  = Join-Path $TestDrive 'match'
            New-Item -Path $script:dir -ItemType Directory -Force | Out-Null

            New-SelfSignedCertificate -CommonName $script:cnA -OutputDirectory $script:dir -Confirm:$false
            New-SelfSignedCertificate -CommonName $script:cnB -OutputDirectory $script:dir -Confirm:$false

            $script:keyA  = Join-Path $script:dir "$($script:cnA)_PRIVATE.key"
            $script:certA = Join-Path $script:dir "$($script:cnA).pem"
            $script:certB = Join-Path $script:dir "$($script:cnB).pem"
        }

        It 'Returns $true for a matching key/cert pair' {
            Test-PrivateKeyCertMatch -PrivateKeyPath $script:keyA -CertificatePath $script:certA | Should -BeTrue
        }

        It 'Returns $false for a mismatched key/cert pair' {
            Test-PrivateKeyCertMatch -PrivateKeyPath $script:keyA -CertificatePath $script:certB | Should -BeFalse
        }
    }

    Context 'Export-Base64Certificate against real DER bytes' {

        It 'Writes a PEM that openssl can re-parse as a valid x509 certificate' {
            $cn  = 'pem.example.com'
            $dir = Join-Path $TestDrive 'pem'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null

            New-SelfSignedCertificate -CommonName $cn -OutputDirectory $dir -Confirm:$false
            $srcPem = Join-Path $dir "$cn.pem"

            # Load the cert and round-trip its DER bytes through
            # Export-Base64Certificate, then ask openssl to parse the result.
            $cert    = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($srcPem)
            $outPath = Join-Path $dir 'roundtrip.crt'
            Export-Base64Certificate -ByteArray $cert.RawData -Path $outPath

            $null = & openssl x509 -in $outPath -noout -text 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }
}
