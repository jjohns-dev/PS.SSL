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

Describe 'Export-PFX' {

    BeforeEach {
        # Mock the openssl and output-directory boundaries; the function
        # itself still uses Get-Content/Set-Content for chain assembly so
        # we let those touch $TestDrive.
        Mock -ModuleName PS.SSL Invoke-OpenSsl             { }
        Mock -ModuleName PS.SSL Initialize-OutputDirectory { }

        # Real placeholder files - the function only inspects extensions
        # and reads contents for the chain merge; it never parses them.
        $script:keyPath  = Join-Path $TestDrive 'mydomain.com.key'
        $script:csrPath  = Join-Path $TestDrive 'mydomain.com.crt'
        $script:rootPath = Join-Path $TestDrive 'root.crt'
        $script:intPath  = Join-Path $TestDrive 'intermediate.crt'
        Set-Content -Path $script:keyPath  -Value 'KEY'
        Set-Content -Path $script:csrPath  -Value 'CERT'
        Set-Content -Path $script:rootPath -Value 'ROOT'
        Set-Content -Path $script:intPath  -Value 'INTERMEDIATE'

        $script:password = ConvertTo-SecureString -String 'NotARealPassword!1' -AsPlainText -Force
    }

    Context 'Parameter validation' {

        It 'Rejects a missing private key path' {
            $params = @{
                Password      = $script:password
                KeyPath       = Join-Path $TestDrive 'missing.key'
                SignedCSRPath = $script:csrPath
                OutputDirectory = $TestDrive
            }
            { Export-PFX @params } | Should -Throw
        }

        It 'Rejects an unsupported private key extension' {
            $bad = Join-Path $TestDrive 'mydomain.com.txt'
            Set-Content -Path $bad -Value 'KEY'
            $params = @{
                Password = $script:password; KeyPath = $bad
                SignedCSRPath = $script:csrPath; OutputDirectory = $TestDrive
            }
            { Export-PFX @params } | Should -Throw
        }

        It 'Declares -RootCAPath as mandatory in the __fullchain parameter set' {
            # When -IntermediateCAPath is supplied PowerShell binds the
            # __fullchain set, which makes -RootCAPath mandatory. Verify the
            # contract via the parameter metadata rather than by invoking
            # the cmdlet (an unsupplied mandatory parameter prompts the host
            # interactively, which would hang an automated test).
            $cmd  = Get-Command -Name 'Export-PFX'
            $root = $cmd.Parameters['RootCAPath']
            $full = $root.ParameterSets['__fullchain']
            $full         | Should -Not -BeNullOrEmpty
            $full.IsMandatory | Should -BeTrue
        }

        It 'Accepts the legacy -Key/-SignedCSR/-RootCA aliases' {
            $params = @{
                Password = $script:password
                Key = $script:keyPath; SignedCSR = $script:csrPath; RootCA = $script:rootPath
                OutputDirectory = $TestDrive
            }
            { Export-PFX @params } | Should -Not -Throw
        }
    }

    Context 'OpenSSL invocation' {

        It 'Calls openssl pkcs12 -export with -inkey, -in, and -out' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'pkcs12') -and
                ($ArgumentList -contains '-export') -and
                ($ArgumentList -contains '-inkey') -and
                ($ArgumentList -contains '-in') -and
                ($ArgumentList -contains '-out')
            }
        }

        It 'Writes the output PFX named after the signed CSR leaf-base, inside the output directory' {
            $result = Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive
            $expected = Join-Path -Path $TestDrive -ChildPath 'mydomain.com.pfx'
            $result | Should -Be $expected
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
                $outIndex -ge 0 -and $ArgumentList[$outIndex + 1] -eq $expected
            }
        }

        It 'Returns the PFX path on the output stream' {
            $result = Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive
            $result | Should -BeOfType ([System.String])
            $result | Should -Match 'mydomain\.com\.pfx$'
        }
    }

    Context 'Certificate chain assembly' {

        It '__nochain: omits -certfile when no CA paths are supplied' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -notcontains '-certfile'
            }
        }

        It '__rootonly: passes -certfile <RootCAPath> directly (no merge file)' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -RootCAPath $script:rootPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $certfileIndex = [System.Array]::IndexOf($ArgumentList, '-certfile')
                $certfileIndex -ge 0 -and $ArgumentList[$certfileIndex + 1] -eq $script:rootPath
            }
        }

        It '__fullchain: builds CAChain.crt with intermediate first, then root' {
            $params = @{
                Password = $script:password; KeyPath = $script:keyPath
                SignedCSRPath = $script:csrPath
                IntermediateCAPath = $script:intPath; RootCAPath = $script:rootPath
                OutputDirectory = $TestDrive
            }
            Export-PFX @params | Out-Null

            $chainPath = Join-Path $TestDrive 'CAChain.crt'
            Test-Path $chainPath | Should -BeTrue
            $contents = Get-Content -Path $chainPath -Raw
            $contents | Should -Match 'INTERMEDIATE'
            $contents | Should -Match 'ROOT'
            ($contents.IndexOf('INTERMEDIATE')) | Should -BeLessThan ($contents.IndexOf('ROOT'))

            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $certfileIndex = [System.Array]::IndexOf($ArgumentList, '-certfile')
                $certfileIndex -ge 0 -and $ArgumentList[$certfileIndex + 1] -eq $chainPath
            }
        }
    }

    Context '-WindowsCompatible' {

        It 'Adds -certpbe, -keypbe PBE-SHA1-3DES, and -nomac' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive -WindowsCompatible | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains '-certpbe')       -and
                ($ArgumentList -contains '-keypbe')        -and
                ($ArgumentList -contains 'PBE-SHA1-3DES')  -and
                ($ArgumentList -contains '-nomac')
            }
        }

        It 'Omits the legacy PBE switches when -WindowsCompatible is not set' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -notcontains '-certpbe') -and
                ($ArgumentList -notcontains '-keypbe')  -and
                ($ArgumentList -notcontains '-nomac')
            }
        }
    }

    Context 'Password handoff (security-critical)' {

        It 'Routes the password via -passout env:PSSL_PASSOUT, never on argv' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $passoutIndex = [System.Array]::IndexOf($ArgumentList, '-passout')
                $passoutIndex -ge 0 -and $ArgumentList[$passoutIndex + 1] -eq 'env:PSSL_PASSOUT'
            }
        }

        It 'Never places the plain-text password on argv' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -notmatch 'NotARealPassword'
            }
        }

        It 'Hands the SecureString to Invoke-OpenSsl via -EnvironmentVariable PSSL_PASSOUT' {
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $EnvironmentVariable -is [hashtable]              -and
                $EnvironmentVariable.ContainsKey('PSSL_PASSOUT')  -and
                $EnvironmentVariable['PSSL_PASSOUT'] -is [System.Security.SecureString]
            }
        }

        It 'Does not leak PSSL_PASSOUT into the parent session environment' {
            $env:PSSL_PASSOUT | Should -BeNullOrEmpty
            Export-PFX -Password $script:password -KeyPath $script:keyPath -SignedCSRPath $script:csrPath -OutputDirectory $TestDrive | Out-Null
            $env:PSSL_PASSOUT | Should -BeNullOrEmpty
        }
    }
}
