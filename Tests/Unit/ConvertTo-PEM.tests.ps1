[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Fixed test-fixture password, not a secret.')]
param ()

BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force
}

Describe 'ConvertTo-PEM' {

    BeforeEach {
        # Mock all external boundaries: openssl, the PFX password sanity
        # check, and the output-directory helper. Get-PfxCertificate is a
        # built-in cmdlet but it is called from inside the module, so it
        # must be mocked with -ModuleName.
        Mock -ModuleName PS.SSL Invoke-OpenSsl             { }
        Mock -ModuleName PS.SSL Initialize-OutputDirectory { }
        Mock -ModuleName PS.SSL Get-PfxCertificate         { }

        $script:pfxPath = Join-Path $TestDrive 'bundle.pfx'
        Set-Content -Path $script:pfxPath -Value 'placeholder'
        $script:password = ConvertTo-SecureString -String 'NotARealPassword!1' -AsPlainText -Force
    }

    Context 'Parameter validation' {

        It 'Rejects a path that does not exist' {
            $missing = Join-Path $TestDrive 'missing.pfx'
            { ConvertTo-PEM -Path $missing -OutputDirectory $TestDrive -Password $script:password } | Should -Throw
        }

        It 'Rejects an unsupported input extension' {
            $bad = Join-Path $TestDrive 'bundle.pem'
            Set-Content -Path $bad -Value 'placeholder'
            { ConvertTo-PEM -Path $bad -OutputDirectory $TestDrive -Password $script:password } | Should -Throw
        }

        It 'Accepts both .pfx and .p12 extensions' {
            foreach ($ext in '.pfx', '.p12') {
                $path = Join-Path $TestDrive ('bundle{0}' -f $ext)
                Set-Content -Path $path -Value 'placeholder'
                { ConvertTo-PEM -Path $path -OutputDirectory $TestDrive -Password $script:password } | Should -Not -Throw
            }
        }

        It 'Accepts the legacy -PFX alias' {
            { ConvertTo-PEM -PFX $script:pfxPath -OutputDirectory $TestDrive -Password $script:password } | Should -Not -Throw
        }

        It 'Requires a non-empty SecureString password' {
            { ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $null } | Should -Throw
        }
    }

    Context 'OpenSSL invocation' {

        It 'Calls openssl pkcs12 with -nodes' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'pkcs12') -and
                ($ArgumentList -contains '-nodes') -and
                ($ArgumentList -contains '-in')    -and
                ($ArgumentList -contains '-out')
            }
        }

        It 'Writes the output as <LeafBase>.pem inside the output directory' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            $expected = Join-Path -Path $TestDrive -ChildPath 'bundle.pem'
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
                $outIndex -ge 0 -and $ArgumentList[$outIndex + 1] -eq $expected
            }
        }

        It 'Validates the password via Get-PfxCertificate before invoking openssl' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            Should -Invoke -ModuleName PS.SSL -CommandName 'Get-PfxCertificate' -Times 1 -Exactly
        }
    }

    Context 'Password handoff (security-critical)' {

        It 'Routes the password via -passin env:PSSL_PASSIN, never on argv' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $passinIndex = [System.Array]::IndexOf($ArgumentList, '-passin')
                $passinIndex -ge 0 -and $ArgumentList[$passinIndex + 1] -eq 'env:PSSL_PASSIN'
            }
        }

        It 'Never places the plain-text password on argv' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -notmatch 'NotARealPassword'
            }
        }

        It 'Hands the SecureString to Invoke-OpenSsl via -EnvironmentVariable PSSL_PASSIN' {
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $EnvironmentVariable -is [hashtable]              -and
                $EnvironmentVariable.ContainsKey('PSSL_PASSIN')   -and
                $EnvironmentVariable['PSSL_PASSIN'] -is [System.Security.SecureString]
            }
        }

        It 'Does not leak PSSL_PASSIN into the parent session environment' {
            $env:PSSL_PASSIN | Should -BeNullOrEmpty
            ConvertTo-PEM -Path $script:pfxPath -OutputDirectory $TestDrive -Password $script:password
            $env:PSSL_PASSIN | Should -BeNullOrEmpty
        }
    }
}
