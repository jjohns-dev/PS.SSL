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

    Context 'Invoke-OpenSsl with more stderr than a pipe buffer holds' {

        It 'Returns instead of deadlocking when openssl writes over 64 KB to stderr' {
            $dir = Join-Path $TestDrive 'stderr'
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            $keyPath = Join-Path $dir 'stderr.key'
            $null = & openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out $keyPath 2>&1
            $LASTEXITCODE | Should -Be 0

            # openssl writes one stderr warning per unknown subject attribute,
            # about 60 bytes each: 3,000 of them exceed any OS pipe buffer while
            # the argument stays under the 32,767-character Windows limit.
            $subject = '/CN=x' + (-join (1..3000 | ForEach-Object { '/z{0}=1' -f $_ }))
            $arguments = @('req', '-new', '-key', $keyPath, '-subj', $subject, '-out', (Join-Path $dir 'stderr.csr'))

            # A thread job with a timeout turns a deadlock into a test failure
            # instead of a hung run.
            $modulePath = (Get-Module -Name 'PS.SSL').Path
            $job = Start-ThreadJob -ScriptBlock {
                $module = Import-Module -Name $using:modulePath -Force -PassThru
                & $module { param($a) Invoke-OpenSsl -ArgumentList $a -IgnoreExitCode } $using:arguments
            }
            try {
                $finished = $null -ne (Wait-Job -Job $job -Timeout 60)
                if (-not $finished) {
                    # Killing the blocked openssl child closes its pipes, which
                    # releases the job thread so cleanup cannot hang too.
                    Get-Process -Name 'openssl' -ErrorAction SilentlyContinue |
                        Where-Object { $_.Parent.Id -eq $PID } |
                        Stop-Process -Force -ErrorAction SilentlyContinue
                }
                $finished | Should -BeTrue -Because 'Invoke-OpenSsl must drain stderr while it reads stdout'

                $result = Receive-Job -Job $job -ErrorAction Stop
                $result.StdErr.Length | Should -BeGreaterThan 65536
            }
            finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
