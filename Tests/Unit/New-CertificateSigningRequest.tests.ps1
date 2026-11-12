BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    # Remove any existing PS.SSL copies first. `-Force` re-imports but does
    # not displace a module already loaded from a different absolute path
    # (e.g. the staged build output vs. the source tree), which would leave
    # two PS.SSL modules in the session and break `Mock -ModuleName PS.SSL`
    # with "Multiple script or manifest modules ... currently loaded".
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force
}

Describe 'New-CertificateSigningRequest' {

    BeforeEach {
        # Mock the module-private boundary so the unit test never touches
        # openssl, never touches disk for the rendered .conf, and never
        # validates the output directory against the filesystem.
        Mock -ModuleName PS.SSL Invoke-OpenSsl          { }
        Mock -ModuleName PS.SSL Initialize-OutputDirectory { }
        Mock -ModuleName PS.SSL Build-CsrConfig         { }
    }

    Context '__input parameter set' {

        It 'Invokes openssl with req/-new/-nodes/-sha256 and the default rsa:4096 key size' {
            New-CertificateSigningRequest -CommonName 'test.example.com' -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $joined = $ArgumentList -join ' '
                ($ArgumentList -contains 'req')     -and
                ($ArgumentList -contains '-new')    -and
                ($ArgumentList -contains '-nodes')  -and
                ($ArgumentList -contains '-sha256') -and
                ($ArgumentList -contains '-newkey') -and
                ($joined -match 'rsa:4096')         -and
                ($joined -match 'test\.example\.com\.csr') -and
                ($joined -match 'test\.example\.com_PRIVATE\.key')
            }
        }

        It 'Delegates config rendering to Build-CsrConfig' {
            New-CertificateSigningRequest -CommonName 'test.example.com' -OutputDirectory $TestDrive -Confirm:$false
            Should -Invoke -ModuleName PS.SSL -CommandName 'Build-CsrConfig' -Times 1 -Exactly
        }

        It 'Emits the requested KeySize verbatim to openssl' {
            New-CertificateSigningRequest -CommonName 'test.example.com' -OutputDirectory $TestDrive -KeySize 2048 -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match 'rsa:2048'
            }
        }

        It 'Rejects an unsupported KeySize via ValidateSet' {
            { New-CertificateSigningRequest -CommonName 'test.example.com' -OutputDirectory $TestDrive -KeySize 1024 -Confirm:$false } |
                Should -Throw
        }

        It 'Skips the openssl invocation when called with -WhatIf' {
            New-CertificateSigningRequest -CommonName 'test.example.com' -OutputDirectory $TestDrive -WhatIf
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 0 -Exactly
        }

        It 'Rejects a CommonName whose TLD is outside the allow-list' {
            { New-CertificateSigningRequest -CommonName 'test.example.xyz' -OutputDirectory $TestDrive -Confirm:$false } |
                Should -Throw
        }
    }

    Context '__conf parameter set' {

        It 'Derives the artifact basename from the CN= line in the supplied config' {
            $confPath = Join-Path $TestDrive 'fromfile.conf'
            Set-Content -Path $confPath -Value @(
                '[req]'
                'prompt = no'
                'distinguished_name = dn'
                '[dn]'
                'CN = www.fromfile.com'
            )

            New-CertificateSigningRequest -ConfigFile $confPath -OutputDirectory $TestDrive -Confirm:$false

            # __conf mode must NOT re-render the config via Build-CsrConfig;
            # it uses the caller's file as-is.
            Should -Invoke -ModuleName PS.SSL -CommandName 'Build-CsrConfig' -Times 0 -Exactly
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl'  -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match 'www\.fromfile\.com\.csr'
            }
        }

        It 'Replaces the wildcard "*" with "star" in derived artifact filenames' {
            # __conf mode reads CN from the caller's file and bypasses the
            # CommonName ValidatePattern, so this is the only path where the
            # wildcard rewrite in New-CertificateSigningRequest is reachable.
            $confPath = Join-Path $TestDrive 'wildcard.conf'
            Set-Content -Path $confPath -Value @(
                '[req]'
                'prompt = no'
                'distinguished_name = dn'
                '[dn]'
                'CN = *.example.com'
            )

            New-CertificateSigningRequest -ConfigFile $confPath -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $joined = $ArgumentList -join ' '
                ($joined -match 'star\.example\.com\.csr') -and
                ($joined -notmatch '\*')
            }
        }
    }
}