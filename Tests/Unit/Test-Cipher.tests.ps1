BeforeDiscovery {
    # Pester evaluates -Skip during discovery, before BeforeAll runs, so
    # the openssl probe must live here. The -Cipher ValidateScript on
    # Test-Cipher calls `openssl ciphers` directly (not via the module's
    # Invoke-OpenSsl wrapper), so the local openssl must be on PATH.
    $script:opensslAvailable = [bool] (Get-Command -Name 'openssl' -CommandType Application -ErrorAction SilentlyContinue)
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

    # Pick the first cipher openssl reports so the test is portable across
    # openssl versions and FIPS builds. Discovery-scope variables aren't
    # visible to It bodies, so the value is resolved again here at runtime.
    $script:validCipher = ((& openssl ciphers 2>$null) -split ':')[0]

    # Indirect the test target through a variable so PSScriptAnalyzer's
    # PSAvoidUsingComputerNameHardcoded rule does not fire on test code
    # that never reaches a real network endpoint (Invoke-OpenSsl is mocked).
    $script:testHost = 'example.com'
}

Describe 'Test-Cipher' -Skip:(-not $script:opensslAvailable) {

    BeforeEach {
        Mock -ModuleName PS.SSL Invoke-OpenSsl {
            [PSCustomObject] @{ ExitCode = 0; StdOut = 'handshake ok'; StdErr = '' }
        }
        # Default the TCP pre-flight to success so the suite never touches the
        # real network. The dedicated short-circuit context overrides this.
        Mock -ModuleName PS.SSL Test-TcpConnection { $true }
    }

    Context 'Parameter validation' {

        It 'Rejects an empty ComputerName' {
            { Test-Cipher -ComputerName ([string]::Empty) -Cipher $script:validCipher } | Should -Throw
        }

        It 'Rejects an out-of-range Port' {
            { Test-Cipher -ComputerName $script:testHost -Port 70000 -Cipher $script:validCipher } | Should -Throw
        }

        It 'Rejects a cipher not in the local openssl cipher list' {
            { Test-Cipher -ComputerName $script:testHost -Cipher 'NOT-A-REAL-CIPHER-XYZ' } | Should -Throw
        }
    }

    Context 'OpenSSL invocation' {

        It 'Calls openssl s_client with -cipher and -connect host:port' {
            Test-Cipher -ComputerName $script:testHost -Port 443 -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 's_client')   -and
                ($ArgumentList -contains '-cipher')    -and
                ($ArgumentList -contains '-connect')
            }
        }

        It 'Forms the -connect endpoint as host:port' {
            Test-Cipher -ComputerName $script:testHost -Port 8443 -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $connectIndex = [System.Array]::IndexOf($ArgumentList, '-connect')
                $connectIndex -ge 0 -and $ArgumentList[$connectIndex + 1] -eq 'example.com:8443'
            }
        }

        It 'Defaults to port 443 when -Port is not supplied' {
            Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $connectIndex = [System.Array]::IndexOf($ArgumentList, '-connect')
                $connectIndex -ge 0 -and $ArgumentList[$connectIndex + 1] -eq 'example.com:443'
            }
        }

        It 'Uses -IgnoreExitCode so a rejected cipher is non-terminating' {
            Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $IgnoreExitCode -eq $true
            }
        }
    }

    Context 'Structured output contract' {

        It 'Returns a PSCustomObject with the full property set' {
            $result = Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher
            $result | Should -BeOfType ([pscustomobject])
            foreach ($prop in 'ComputerName', 'Port', 'Cipher', 'Supported', 'Error') {
                $result.PSObject.Properties.Name | Should -Contain $prop
            }
        }

        It 'Sets Supported=$true and Error=$null on ExitCode 0' {
            $result = Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher
            $result.Supported | Should -BeTrue
            $result.Error     | Should -BeNullOrEmpty
        }

        It 'Sets Supported=$false and surfaces trimmed stderr on non-zero exit' {
            Mock -ModuleName PS.SSL Invoke-OpenSsl {
                [PSCustomObject] @{ ExitCode = 1; StdOut = ''; StdErr = "  handshake failure  `n" }
            }
            $result = Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher
            $result.Supported | Should -BeFalse
            $result.Error     | Should -Be 'handshake failure'
        }

        It 'Echoes ComputerName, Port, and Cipher to the output object verbatim' {
            $result = Test-Cipher -ComputerName $script:testHost -Port 8443 -Cipher $script:validCipher
            $result.ComputerName | Should -Be 'example.com'
            $result.Port         | Should -Be 8443
            $result.Cipher       | Should -Be $script:validCipher
        }
    }

    Context 'TCP pre-flight short-circuit' {

        BeforeEach {
            Mock -ModuleName PS.SSL Test-TcpConnection { $false }
        }

        It 'Skips Invoke-OpenSsl when the TCP probe fails' {
            Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 0 -Exactly
        }

        It 'Returns Supported=$false with a timeout error message' {
            $result = Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher
            $result.Supported | Should -BeFalse
            $result.Error    | Should -Match 'TCP connect to example.com:443 (failed|timed out)'
        }

        It 'Passes -TimeoutSeconds (in ms) to the TCP probe' {
            Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher -TimeoutSeconds 7 | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Test-TcpConnection' -Times 1 -Exactly -ParameterFilter {
                $TimeoutMilliseconds -eq 7000
            }
        }

        It 'Defaults TimeoutSeconds to 3 (3000ms) when not supplied' {
            Test-Cipher -ComputerName $script:testHost -Cipher $script:validCipher | Out-Null
            Should -Invoke -ModuleName PS.SSL -CommandName 'Test-TcpConnection' -Times 1 -Exactly -ParameterFilter {
                $TimeoutMilliseconds -eq 3000
            }
        }
    }
}
