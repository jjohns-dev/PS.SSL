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

Describe 'ConvertFrom-PKCS7' {

    BeforeEach {
        # Mock the openssl boundary and the output-directory helper so the
        # unit test never touches openssl and never validates paths against
        # the real filesystem.
        Mock -ModuleName PS.SSL Invoke-OpenSsl           { }
        Mock -ModuleName PS.SSL Initialize-OutputDirectory { }
    }

    Context 'Parameter validation' {

        It 'Rejects a path that does not exist' {
            $missing = Join-Path $TestDrive 'does-not-exist.cer'
            { ConvertFrom-PKCS7 -Path $missing -OutputDirectory $TestDrive } | Should -Throw
        }

        It 'Rejects an unsupported input extension' {
            $bad = Join-Path $TestDrive 'cert.pfx'
            Set-Content -Path $bad -Value 'placeholder'
            { ConvertFrom-PKCS7 -Path $bad -OutputDirectory $TestDrive } | Should -Throw
        }

        It 'Accepts .crt, .cer, and .pem extensions' {
            foreach ($ext in '.crt', '.cer', '.pem') {
                $path = Join-Path $TestDrive ('cert{0}' -f $ext)
                Set-Content -Path $path -Value 'placeholder'
                { ConvertFrom-PKCS7 -Path $path -OutputDirectory $TestDrive } | Should -Not -Throw
            }
        }
    }

    Context 'OpenSSL invocation' {

        BeforeEach {
            $script:inputPath = Join-Path $TestDrive 'mycert.cer'
            Set-Content -Path $script:inputPath -Value 'placeholder'
        }

        It 'Calls openssl pkcs7 with -print_certs' {
            ConvertFrom-PKCS7 -Path $script:inputPath -OutputDirectory $TestDrive
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'pkcs7')        -and
                ($ArgumentList -contains '-print_certs') -and
                ($ArgumentList -contains '-in')          -and
                ($ArgumentList -contains '-out')
            }
        }

        It 'Passes the input path via -in' {
            ConvertFrom-PKCS7 -Path $script:inputPath -OutputDirectory $TestDrive
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $inIndex = [System.Array]::IndexOf($ArgumentList, '-in')
                $inIndex -ge 0 -and $ArgumentList[$inIndex + 1] -eq $script:inputPath
            }
        }

        It 'Writes the output as <LeafBase>.crt inside the output directory' {
            ConvertFrom-PKCS7 -Path $script:inputPath -OutputDirectory $TestDrive
            $expected = Join-Path -Path $TestDrive -ChildPath 'mycert.crt'
            Should -Invoke -ModuleName PS.SSL -CommandName 'Invoke-OpenSsl' -Times 1 -Exactly -ParameterFilter {
                $outIndex = [System.Array]::IndexOf($ArgumentList, '-out')
                $outIndex -ge 0 -and $ArgumentList[$outIndex + 1] -eq $expected
            }
        }

        It 'Ensures the output directory is initialized before invoking openssl' {
            ConvertFrom-PKCS7 -Path $script:inputPath -OutputDirectory $TestDrive
            Should -Invoke -ModuleName PS.SSL -CommandName 'Initialize-OutputDirectory' -Times 1 -Exactly
        }
    }
}
