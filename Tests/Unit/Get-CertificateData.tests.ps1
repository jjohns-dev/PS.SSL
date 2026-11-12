BeforeDiscovery {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    if (-not (Get-Module -Name 'PS.SSL')) {
        Import-Module -Name $manifestPath -ErrorAction Stop -Force
    }
}

BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force

    # HELPER: CREATE AN IN-MEMORY SELF-SIGNED CERT FOR FIXTURE USE
    function New-FixtureCert ([System.String] $Subject) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                ('CN={0}' -f $Subject), $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CreateSelfSigned([datetimeoffset]::UtcNow.AddDays(-1), [datetimeoffset]::UtcNow.AddDays(30))
        }
        finally { $rsa.Dispose() }
    }

    # HELPER: CONVERT DER BYTES TO A PEM-ENCODED STRING
    function ConvertTo-PemString ([System.Byte[]] $Der) {
        $b64 = [System.Convert]::ToBase64String($Der, [System.Base64FormattingOptions]::InsertLineBreaks)
        '-----BEGIN CERTIFICATE-----{0}{1}{0}-----END CERTIFICATE-----' -f "`n", $b64
    }

    # GENERATE THREE CERTS FOR SINGLE-CERT AND BUNDLE FIXTURE SCENARIOS
    $script:cert1 = New-FixtureCert -Subject 'PSSL Unit Test'
    $script:cert2 = New-FixtureCert -Subject 'PSSL Intermediate CA'
    $script:cert3 = New-FixtureCert -Subject 'PSSL Root CA'

    $script:fixtureDer         = $script:cert1.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $script:fixtureDer2        = $script:cert2.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $script:fixtureDer3        = $script:cert3.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $script:fixtureThumbprint  = $script:cert1.Thumbprint
    $script:fixtureThumbprint2 = $script:cert2.Thumbprint
    $script:fixtureThumbprint3 = $script:cert3.Thumbprint

    # THREE-CERT PEM BUNDLE (LEAF + INTERMEDIATE + ROOT) USED IN BUNDLE TESTS
    $script:bundlePem = @(
        ConvertTo-PemString -Der $script:fixtureDer
        ConvertTo-PemString -Der $script:fixtureDer2
        ConvertTo-PemString -Der $script:fixtureDer3
    ) -join "`n"

    # ORDERED DER BYTES FOR THE BUNDLE — CONSUMED BY THE STATEFUL MOCK
    $script:bundleDerBytes = @($script:fixtureDer, $script:fixtureDer2, $script:fixtureDer3)
}

AfterAll {
    $script:cert1.Dispose()
    $script:cert2.Dispose()
    $script:cert3.Dispose()
}

Describe -Name 'Get-CertificateData' -Fixture {

    BeforeEach {
        # MOCK THE MODULE-PRIVATE OPENSSL BOUNDARY — LOCATES THE -OUT ARGUMENT
        # AND WRITES FIXTURE DER BYTES TO THAT PATH INSTEAD OF INVOKING OPENSSL
        Mock -ModuleName PS.SSL -CommandName Invoke-OpenSsl -MockWith {
            $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
            if ($outIndex -ge 0 -and $outIndex + 1 -lt $ArgumentList.Length) {
                $outPath = $ArgumentList[$outIndex + 1]
                [System.IO.File]::WriteAllBytes($outPath, $script:fixtureDer)
            }
            [PSCustomObject] @{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
    }

    Context -Name 'Parameter validation' -Fixture {

        It -Name 'rejects a path that does not exist' -Test {
            $missing = Join-Path -Path $TestDrive -ChildPath 'does-not-exist.pem'
            { Get-CertificateData -Path $missing } | Should -Throw
        }

        It -Name 'rejects a path with an unsupported extension' -Test {
            $bad = Join-Path -Path $TestDrive -ChildPath 'cert.txt'
            Set-Content -Path $bad -Value 'placeholder'
            { Get-CertificateData -Path $bad } | Should -Throw
        }

        It -Name 'accepts .pem, .crt, and .cer extensions' -Test {
            foreach ($ext in '.pem', '.crt', '.cer') {
                $path = Join-Path -Path $TestDrive -ChildPath ('cert{0}' -f $ext)
                Set-Content -Path $path -Value 'placeholder'
                { Get-CertificateData -Path $path } | Should -Not -Throw
            }
        }
    }

    Context -Name 'OpenSSL invocation' -Fixture {

        BeforeEach {
            $script:certPath = Join-Path -Path $TestDrive -ChildPath 'cert.pem'
            Set-Content -Path $script:certPath -Value 'placeholder'
        }

        It -Name 'invokes openssl x509 with -outform DER' -Test {
            Get-CertificateData -Path $script:certPath | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'x509')     -and
                ($ArgumentList -contains '-in')      -and
                ($ArgumentList -contains '-outform') -and
                ($ArgumentList -contains 'DER')      -and
                ($ArgumentList -contains '-out')
            }
        }

        It -Name 'passes the input file path to openssl via -in for a single-cert file' -Test {
            Get-CertificateData -Path $script:certPath | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $inIndex = [System.Array]::IndexOf($ArgumentList, '-in')
                $inIndex -ge 0 -and $ArgumentList[$inIndex + 1] -eq $script:certPath
            }
        }
    }

    Context -Name 'Return type — single certificate' -Fixture {

        BeforeEach {
            $script:certPath = Join-Path -Path $TestDrive -ChildPath 'cert.pem'
            Set-Content -Path $script:certPath -Value 'placeholder'
        }

        It -Name 'returns an X509Certificate2 instance' -Test {
            $result = Get-CertificateData -Path $script:certPath
            $result | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
        }

        It -Name 'returns the certificate constructed from openssl-normalized DER bytes' -Test {
            $result = Get-CertificateData -Path $script:certPath
            $result.Thumbprint | Should -Be $script:fixtureThumbprint
            $result.Subject    | Should -Match 'PSSL Unit Test'
        }

        It -Name 'cleans up the temporary DER file after constructing the certificate' -Test {
            $tempBefore = Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue
            Get-CertificateData -Path $script:certPath | Out-Null
            $tempAfter = Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue
            $tempAfter.Count | Should -Be $tempBefore.Count
        }
    }

    Context -Name 'Multi-certificate PEM bundle' -Fixture {

        BeforeEach {
            $script:bundlePath = Join-Path -Path $TestDrive -ChildPath 'fullchain.pem'
            Set-Content -Path $script:bundlePath -Value $script:bundlePem

            # STATEFUL MOCK: EACH CALL WRITES THE NEXT CERT'S DER BYTES SO THE
            # RETURNED OBJECTS REFLECT THE CORRECT PER-BLOCK FIXTURE THUMBPRINTS
            $script:mockCallIndex = 0
            Mock -ModuleName PS.SSL -CommandName Invoke-OpenSsl -MockWith {
                $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
                if ($outIndex -ge 0 -and $outIndex + 1 -lt $ArgumentList.Length) {
                    $outPath = $ArgumentList[$outIndex + 1]
                    [System.IO.File]::WriteAllBytes($outPath, $script:bundleDerBytes[$script:mockCallIndex])
                }
                $script:mockCallIndex++
                [PSCustomObject] @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
        }

        It -Name 'returns 3 X509Certificate2 objects for a 3-cert bundle' -Test {
            $results = @(Get-CertificateData -Path $script:bundlePath)
            $results.Count | Should -Be 3
        }

        It -Name 'each returned object is an X509Certificate2 instance' -Test {
            $results = @(Get-CertificateData -Path $script:bundlePath)
            foreach ($r in $results) {
                $r | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
            }
        }

        It -Name 'invokes openssl once per certificate block' -Test {
            Get-CertificateData -Path $script:bundlePath | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 3 -Exactly
        }

        It -Name 'returns certificates in bundle order' -Test {
            $results = @(Get-CertificateData -Path $script:bundlePath)
            $results[0].Thumbprint | Should -Be $script:fixtureThumbprint
            $results[1].Thumbprint | Should -Be $script:fixtureThumbprint2
            $results[2].Thumbprint | Should -Be $script:fixtureThumbprint3
        }

        It -Name 'cleans up all temporary PEM and DER files after processing the bundle' -Test {
            $derBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue)
            $pemBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.pem' -ErrorAction SilentlyContinue)
            Get-CertificateData -Path $script:bundlePath | Out-Null
            $derAfter  = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue)
            $pemAfter  = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.pem' -ErrorAction SilentlyContinue)
            $derAfter.Count | Should -Be $derBefore.Count
            $pemAfter.Count | Should -Be $pemBefore.Count
        }

        It -Name 'propagates a terminating error when openssl fails mid-bundle and still cleans up temp files' -Test {
            Mock -ModuleName PS.SSL -CommandName Invoke-OpenSsl -MockWith {
                if ($script:mockCallIndex -eq 1) { Write-Error -Message 'openssl error: invalid certificate' -ErrorAction Stop }
                $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
                if ($outIndex -ge 0 -and $outIndex + 1 -lt $ArgumentList.Length) {
                    [System.IO.File]::WriteAllBytes($ArgumentList[$outIndex + 1], $script:bundleDerBytes[$script:mockCallIndex])
                }
                $script:mockCallIndex++
                [PSCustomObject] @{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            $derBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue)
            $pemBefore = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.pem' -ErrorAction SilentlyContinue)
            { Get-CertificateData -Path $script:bundlePath } | Should -Throw
            $derAfter = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.der' -ErrorAction SilentlyContinue)
            $pemAfter = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'pssl-cert-*.pem' -ErrorAction SilentlyContinue)
            $derAfter.Count | Should -Be $derBefore.Count
            $pemAfter.Count | Should -Be $pemBefore.Count
        }
    }
}
