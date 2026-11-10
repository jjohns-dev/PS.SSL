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

Describe 'Export-Base64Certificate' {

    Context 'Parameter validation' {
        It 'Rejects an empty byte array' {
            { Export-Base64Certificate -ByteArray @() -Path (Join-Path $TestDrive 'empty.crt') } | Should -Throw
        }

        It 'Rejects a path that does not end in .crt' {
            { Export-Base64Certificate -ByteArray ([byte[]](1, 2, 3)) -Path (Join-Path $TestDrive 'wrong-ext.pem') } | Should -Throw
        }

        It 'Rejects a path whose parent directory does not exist' {
            { Export-Base64Certificate -ByteArray ([byte[]](1, 2, 3)) -Path (Join-Path $TestDrive 'no\such\dir\out.crt') } | Should -Throw
        }

        It 'Rejects a path that already exists' {
            $existing = Join-Path $TestDrive 'already-there.crt'
            Set-Content -Path $existing -Value 'placeholder'
            { Export-Base64Certificate -ByteArray ([byte[]](1, 2, 3)) -Path $existing } | Should -Throw
        }
    }

    Context 'PEM output format' {

        BeforeAll {
            # 256 bytes -> 344 base64 chars -> six 64-char lines + one 56-char tail
            $script:bytes   = [byte[]](0..255)
            $script:outPath = Join-Path $TestDrive 'roundtrip.crt'
            Export-Base64Certificate -ByteArray $script:bytes -Path $script:outPath
            $script:lines   = Get-Content -Path $script:outPath
        }

        It 'Writes the PEM BEGIN CERTIFICATE header on the first line' {
            $script:lines[0] | Should -BeExactly '-----BEGIN CERTIFICATE-----'
        }

        It 'Writes the PEM END CERTIFICATE footer on the last line' {
            $script:lines[-1] | Should -BeExactly '-----END CERTIFICATE-----'
        }

        It 'Wraps every body line except the last at 64 characters (RFC 7468)' {
            $body = $script:lines[1..($script:lines.Length - 2)]
            $body.Length | Should -BeGreaterThan 0
            foreach ($line in $body[0..($body.Length - 2)]) {
                $line.Length | Should -Be 64
            }
        }

        It 'Caps the last body line at 64 characters or fewer' {
            $body = $script:lines[1..($script:lines.Length - 2)]
            $body[-1].Length | Should -BeLessOrEqual 64
        }

        It 'Round-trips through base64 decoding back to the original bytes' {
            $body    = ($script:lines[1..($script:lines.Length - 2)]) -join ''
            $decoded = [System.Convert]::FromBase64String($body)
            $decoded | Should -Be $script:bytes
        }
    }
}
