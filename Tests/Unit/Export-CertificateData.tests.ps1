BeforeAll {
    $manifestPath = if ($env:BHPSModuleManifest) {
        $env:BHPSModuleManifest
    }
    else {
        Join-Path -Path $PSScriptRoot -ChildPath '..\..\PS.SSL.psd1' | Resolve-Path | Select-Object -ExpandProperty Path
    }
    Get-Module -Name 'PS.SSL' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module -Name $manifestPath -Force

    # Synthetic PEM bundle: 1 private key + 3 certificates (leaf + 2 chain).
    # The actual base64 content is filler - Export-CertificateData scans for
    # the standard PEM begin/end markers and slices line ranges verbatim; it
    # never decodes the base64 body.
    $script:samplePem = @(
        '-----BEGIN PRIVATE KEY-----'
        'AAAAKEYLINE1'
        'AAAAKEYLINE2'
        '-----END PRIVATE KEY-----'
        '-----BEGIN CERTIFICATE-----'
        'BBBBLEAFLINE1'
        'BBBBLEAFLINE2'
        '-----END CERTIFICATE-----'
        '-----BEGIN CERTIFICATE-----'
        'CCCCCHAIN1LINE1'
        '-----END CERTIFICATE-----'
        '-----BEGIN CERTIFICATE-----'
        'DDDDCHAIN2LINE1'
        '-----END CERTIFICATE-----'
    ) -join [System.Environment]::NewLine
}

Describe 'Export-CertificateData' {

    Context 'Parameter validation' {

        It 'Rejects a path that does not exist' {
            $missing = Join-Path $TestDrive 'does-not-exist.pem'
            { Export-CertificateData -Path $missing -Data Certificate -OutputDirectory $TestDrive } | Should -Throw
        }

        It 'Rejects a path that does not end in .pem' {
            $wrongExt = Join-Path $TestDrive 'bundle.txt'
            Set-Content -Path $wrongExt -Value $script:samplePem
            { Export-CertificateData -Path $wrongExt -Data Certificate -OutputDirectory $TestDrive } | Should -Throw
        }

        It 'Rejects an unsupported -Data value via ValidateSet' {
            $bundle = Join-Path $TestDrive 'bundle.pem'
            Set-Content -Path $bundle -Value $script:samplePem
            { Export-CertificateData -Path $bundle -Data NotARealValue -OutputDirectory $TestDrive } | Should -Throw
        }
    }

    Context 'Certificate extraction' {

        BeforeEach {
            $script:bundle = Join-Path $TestDrive 'bundle.pem'
            Set-Content -Path $script:bundle -Value $script:samplePem
            $script:outDir = Join-Path $TestDrive ('out-{0}' -f ([guid]::NewGuid().Guid.Substring(0, 8)))
            New-Item -Path $script:outDir -ItemType Directory -Force | Out-Null
        }

        It 'Writes certificate.pem containing only the first CERTIFICATE block' {
            Export-CertificateData -Path $script:bundle -Data Certificate -OutputDirectory $script:outDir
            $cert = Join-Path $script:outDir 'certificate.pem'
            Test-Path -Path $cert | Should -BeTrue
            $content = Get-Content -Path $cert
            $content[0]  | Should -BeExactly '-----BEGIN CERTIFICATE-----'
            $content[-1] | Should -BeExactly '-----END CERTIFICATE-----'
            ($content -join "`n") | Should -Match 'BBBBLEAFLINE'
            ($content -join "`n") | Should -Not -Match 'CCCCCHAIN1'
            ($content -join "`n") | Should -Not -Match 'DDDDCHAIN2'
        }

        It 'Writes chain.pem containing the 2nd and 3rd CERTIFICATE blocks' {
            Export-CertificateData -Path $script:bundle -Data Chain -OutputDirectory $script:outDir
            $chain = Join-Path $script:outDir 'chain.pem'
            Test-Path -Path $chain | Should -BeTrue
            $joined = (Get-Content -Path $chain) -join "`n"
            $joined | Should -Match 'CCCCCHAIN1'
            $joined | Should -Match 'DDDDCHAIN2'
            $joined | Should -Not -Match 'BBBBLEAFLINE'
        }

        It 'Writes PRIVATE.key containing only the PRIVATE KEY block' {
            Export-CertificateData -Path $script:bundle -Data PrivateKey -OutputDirectory $script:outDir
            $key = Join-Path $script:outDir 'PRIVATE.key'
            Test-Path -Path $key | Should -BeTrue
            $content = Get-Content -Path $key
            $content[0]  | Should -BeExactly '-----BEGIN PRIVATE KEY-----'
            $content[-1] | Should -BeExactly '-----END PRIVATE KEY-----'
            ($content -join "`n") | Should -Match 'AAAAKEYLINE'
            ($content -join "`n") | Should -Not -Match 'CERTIFICATE'
        }

        It 'Creates the output directory if it does not yet exist' {
            $newDir = Join-Path $TestDrive ('fresh-{0}' -f ([guid]::NewGuid().Guid.Substring(0, 8)))
            Export-CertificateData -Path $script:bundle -Data Certificate -OutputDirectory $newDir
            Test-Path -Path $newDir -PathType Container | Should -BeTrue
            Test-Path -Path (Join-Path $newDir 'certificate.pem') | Should -BeTrue
        }
    }
}
