BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force

    # Representative openssl `req -text -noout -verify` output for a 4096-bit
    # RSA CSR with two SANs. The trailing "Certificate request self-signature
    # verify OK" line is what the function uses to set the Verified property.
    # Built as an array and joined so indentation aligns with surrounding code;
    # the function parses StdOut as a single multi-line string.
    $script:opensslStdOut = @(
        'Certificate request self-signature verify OK'
        'Certificate Request:'
        '    Data:'
        '        Version: 1 (0x0)'
        '        Subject: C = US, ST = California, L = Redlands, O = Esri, OU = IT, CN = test.example.com, emailAddress = admin@example.com'
        '        Subject Public Key Info:'
        '            Public Key Algorithm: rsaEncryption'
        '                Public-Key: (4096 bit)'
        '                Modulus:'
        '                    00:aa:bb:cc:dd'
        '                Exponent: 65537 (0x10001)'
        '        Attributes:'
        '        Requested Extensions:'
        '            X509v3 Key Usage:'
        '                Key Encipherment, Data Encipherment'
        '            X509v3 Extended Key Usage:'
        '                TLS Web Server Authentication'
        '            X509v3 Subject Alternative Name:'
        '                DNS:a.example.com, DNS:b.example.com'
        '    Signature Algorithm: sha256WithRSAEncryption'
        '    Signature Value:'
        '        00:11:22:33:44:55'
    ) -join [System.Environment]::NewLine

    $script:opensslStdOutFailed = $script:opensslStdOut -replace 'self-signature verify OK', 'Signature did not match the certificate request'
}

Describe 'Get-CSRData' {

    Context 'Parameter validation' {

        It 'Rejects a path that does not exist' {
            $missing = Join-Path $TestDrive 'does-not-exist.csr'
            { Get-CSRData -Path $missing } | Should -Throw
        }

        It 'Rejects a path with the wrong extension' {
            $bad = Join-Path $TestDrive 'request.txt'
            Set-Content -Path $bad -Value 'placeholder'
            { Get-CSRData -Path $bad } | Should -Throw
        }

        It 'Accepts the legacy -CSR alias' {
            $csrPath = Join-Path $TestDrive 'alias.csr'
            Set-Content -Path $csrPath -Value 'placeholder'
            Mock -ModuleName PS.SSL Invoke-OpenSsl {
                [PSCustomObject] @{ ExitCode = 0; StdOut = $script:opensslStdOut; StdErr = '' }
            }
            { Get-CSRData -CSR $csrPath } | Should -Not -Throw
        }
    }

    Context 'OpenSSL invocation' {

        BeforeEach {
            $script:csrPath = Join-Path $TestDrive 'sample.csr'
            Set-Content -Path $script:csrPath -Value 'placeholder'
            Mock -ModuleName PS.SSL Invoke-OpenSsl {
                [PSCustomObject] @{ ExitCode = 0; StdOut = $script:opensslStdOut; StdErr = '' }
            }
        }

        It 'Calls openssl req with -text -noout -verify' {
            Get-CSRData -Path $script:csrPath | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'req')     -and
                ($ArgumentList -contains '-text')   -and
                ($ArgumentList -contains '-noout')  -and
                ($ArgumentList -contains '-verify') -and
                ($ArgumentList -contains '-in')
            }
        }

        It 'Uses -IgnoreExitCode so a failed verification is non-terminating' {
            Get-CSRData -Path $script:csrPath | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $IgnoreExitCode -eq $true
            }
        }
    }

    Context 'Parsed output shape' {

        BeforeEach {
            $script:csrPath = Join-Path $TestDrive 'sample.csr'
            Set-Content -Path $script:csrPath -Value 'placeholder'
            Mock -ModuleName PS.SSL Invoke-OpenSsl {
                [PSCustomObject] @{ ExitCode = 0; StdOut = $script:opensslStdOut; StdErr = '' }
            }
            $script:result = Get-CSRData -Path $script:csrPath
        }

        It 'Returns a PSCustomObject with the full property contract' {
            $script:result | Should -BeOfType ([pscustomobject])
            foreach ($prop in 'Path', 'Subject', 'PublicKeyAlgorithm', 'PublicKeyBits',
                              'SignatureAlgorithm', 'SubjectAlternativeName', 'Verified', 'Raw') {
                $script:result.PSObject.Properties.Name | Should -Contain $prop
            }
        }

        It 'Echoes the input path verbatim' {
            $script:result.Path | Should -Be $script:csrPath
        }

        It 'Parses the Subject DN' {
            $script:result.Subject | Should -Match 'CN = test\.example\.com'
        }

        It 'Parses the public key algorithm and bit length' {
            $script:result.PublicKeyAlgorithm | Should -Be 'rsaEncryption'
            $script:result.PublicKeyBits      | Should -Be 4096
        }

        It 'Parses the signature algorithm (last occurrence wins)' {
            $script:result.SignatureAlgorithm | Should -Be 'sha256WithRSAEncryption'
        }

        It 'Parses SANs as a flat string array of DNS names' {
            $script:result.SubjectAlternativeName | Should -Be @('a.example.com', 'b.example.com')
        }

        It 'Sets Verified=$true when openssl reports verification OK' {
            $script:result.Verified | Should -BeTrue
        }

        It 'Preserves the full openssl output on the Raw property' {
            $script:result.Raw | Should -Match 'Certificate Request:'
            $script:result.Raw | Should -Match 'Subject Public Key Info:'
        }
    }

    Context 'Failed verification' {

        It 'Sets Verified=$false when openssl reports a signature mismatch' {
            $csrPath = Join-Path $TestDrive 'bad.csr'
            Set-Content -Path $csrPath -Value 'placeholder'
            Mock -ModuleName PS.SSL Invoke-OpenSsl {
                [PSCustomObject] @{ ExitCode = 1; StdOut = $script:opensslStdOutFailed; StdErr = '' }
            }
            $result = Get-CSRData -Path $csrPath
            $result.Verified | Should -BeFalse
        }
    }
}
