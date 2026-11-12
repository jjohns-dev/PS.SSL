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

Describe 'Get-CSRTemplate' {

    Context 'Output shape' {

        BeforeAll {
            $script:template = Get-CSRTemplate
        }

        It 'Returns a non-empty string array' {
            $script:template | Should -Not -BeNullOrEmpty
            $script:template.GetType().Name | Should -Be 'Object[]'
            $script:template.Count | Should -BeGreaterThan 0
        }

        It 'Returns one element per template line (no embedded newlines)' {
            foreach ($line in $script:template) {
                $line | Should -BeOfType ([string])
                $line | Should -Not -Match "`n"
            }
        }
    }

    Context 'Template content' {

        BeforeAll {
            $script:template = Get-CSRTemplate
            $script:joined = $script:template -join "`n"
        }

        It 'Starts with the [req] section header' {
            $script:template[0] | Should -BeExactly '[req]'
        }

        It 'Includes all required openssl req sections' {
            $script:joined | Should -Match '\[req\]'
            $script:joined | Should -Match '\[req_distinguished_name\]'
            $script:joined | Should -Match '\[v3_req\]'
            $script:joined | Should -Match '\[alt_names\]'
        }

        It 'Sets prompt to no for unattended generation' {
            $script:joined | Should -Match 'prompt\s*=\s*no'
        }

        It 'Sets default key size to 4096 and digest to sha256' {
            $script:joined | Should -Match 'default_bits\s*=\s*4096'
            $script:joined | Should -Match 'default_md\s*=\s*sha256'
        }

        It 'Includes all expected #TOKEN# placeholders for Build-CsrConfig' {
            foreach ($token in '#C#', '#ST#', '#L#', '#O#', '#OU#', '#E#', '#CN#') {
                $script:joined | Should -Match ([regex]::Escape($token))
            }
        }

        It 'Declares serverAuth extended key usage' {
            $script:joined | Should -Match 'extendedKeyUsage\s*=\s*serverAuth'
        }

        It 'References alt_names section via subjectAltName' {
            $script:joined | Should -Match 'subjectAltName\s*=\s*@alt_names'
        }
    }

    Context 'Pipeline usability' {

        It 'Pipes to Set-Content to produce a readable file' {
            $outFile = Join-Path $TestDrive 'template.conf'
            Get-CSRTemplate | Set-Content -Path $outFile
            Test-Path -Path $outFile | Should -BeTrue
            (Get-Content -Path $outFile)[0] | Should -BeExactly '[req]'
        }
    }
}
