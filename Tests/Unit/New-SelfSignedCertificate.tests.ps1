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

Describe 'New-SelfSignedCertificate' {

    BeforeEach {
        # Mock the module-private boundary so the unit test never touches
        # openssl, never writes a .conf, and never validates paths against
        # the real filesystem.
        Mock -ModuleName PS.SSL Invoke-OpenSsl             { }
        Mock -ModuleName PS.SSL Initialize-OutputDirectory { }
        Mock -ModuleName PS.SSL Build-CsrConfig            { }
    }

    Context '__input parameter set' {

        It 'Invokes openssl req -x509 with -new -nodes -sha256 and default rsa:4096' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $joined = $ArgumentList -join ' '
                ($ArgumentList -contains 'req')     -and
                ($ArgumentList -contains '-x509')   -and
                ($ArgumentList -contains '-new')    -and
                ($ArgumentList -contains '-nodes')  -and
                ($ArgumentList -contains '-sha256') -and
                ($ArgumentList -contains '-newkey') -and
                ($joined -match 'rsa:4096')         -and
                ($joined -match 'test\.example\.com\.pem')         -and
                ($joined -match 'test\.example\.com_PRIVATE\.key')
            }
        }

        It 'Delegates config rendering to Build-CsrConfig' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -Confirm:$false
            Should -Invoke -ModuleName PS.SSL -CommandName 'Build-CsrConfig' -Times 1 -Exactly
        }

        It 'Emits the requested KeySize verbatim to openssl' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -KeySize 2048 -Confirm:$false
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match 'rsa:2048'
            }
        }

        It 'Emits -days with the requested validity period' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -Days 730 -Confirm:$false
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $daysIndex = [System.Array]::IndexOf($ArgumentList, '-days')
                $daysIndex -ge 0 -and $ArgumentList[$daysIndex + 1] -eq '730'
            }
        }

        It 'Defaults to 365 days when -Days is not supplied' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -Confirm:$false
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $daysIndex = [System.Array]::IndexOf($ArgumentList, '-days')
                $daysIndex -ge 0 -and $ArgumentList[$daysIndex + 1] -eq '365'
            }
        }

        It 'Rejects an unsupported KeySize via ValidateSet' {
            { New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -KeySize 1024 -Confirm:$false } | Should -Throw
        }

        It 'Rejects an out-of-range -Days value' {
            { New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -Days 10 -Confirm:$false } | Should -Throw
        }

        It 'Rejects an invalid CommonName pattern' {
            { New-SelfSignedCertificate -CommonName 'invalid host name!' -OutputDirectory $TestDrive -Confirm:$false } | Should -Throw
        }

    }

    Context '__conf parameter set' {

        It 'Sanitizes a wildcard CN from the config file to "star" in output file names' {
            $confPath = Join-Path $TestDrive 'wildcard.conf'
            Set-Content -Path $confPath -Value @('[req]', 'prompt = no', 'CN = *.example.com')

            New-SelfSignedCertificate -ConfigFile $confPath -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $joined = $ArgumentList -join ' '
                ($joined -match 'star\.example\.com\.pem') -and
                ($joined -match 'star\.example\.com_PRIVATE\.key') -and
                ($joined -notmatch '\*')
            }
        }

        It 'Uses the caller-supplied -ConfigFile and skips Build-CsrConfig' {
            $confPath = Join-Path $TestDrive 'custom.conf'
            Set-Content -Path $confPath -Value @('[req]', 'prompt = no', 'CN = conf.example.com')

            New-SelfSignedCertificate -ConfigFile $confPath -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Build-CsrConfig' -Times 0 -Exactly
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $configIndex = [System.Array]::IndexOf($ArgumentList, '-config')
                $configIndex -ge 0 -and $ArgumentList[$configIndex + 1] -eq $confPath
            }
        }

        It 'Derives the artifact basename from the CN line in the config file' {
            $confPath = Join-Path $TestDrive 'custom.conf'
            Set-Content -Path $confPath -Value @('[req]', 'prompt = no', 'CN = conf.example.com')

            New-SelfSignedCertificate -ConfigFile $confPath -OutputDirectory $TestDrive -Confirm:$false

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $joined = $ArgumentList -join ' '
                ($joined -match 'conf\.example\.com\.pem') -and
                ($joined -match 'conf\.example\.com_PRIVATE\.key')
            }
        }

        It 'Rejects a config file with the wrong extension' {
            $bad = Join-Path $TestDrive 'custom.txt'
            Set-Content -Path $bad -Value 'placeholder'
            { New-SelfSignedCertificate -ConfigFile $bad -OutputDirectory $TestDrive -Confirm:$false } | Should -Throw
        }
    }

    Context 'ShouldProcess' {

        It 'Skips Invoke-OpenSsl under -WhatIf' {
            New-SelfSignedCertificate -CommonName 'test.example.com' -OutputDirectory $TestDrive -WhatIf
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 0 -Exactly
        }
    }
}
