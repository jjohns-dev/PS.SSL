BeforeDiscovery {
    # Probe a well-known TLS endpoint at discovery time so CI runners
    # without outbound network access skip cleanly instead of failing.
    # `badssl.com` is a public TLS test endpoint maintained for exactly
    # this kind of probe; if it's reachable we have a high-quality target.
    $script:NetworkTarget = 'badssl.com'
    $script:NetworkPort   = 443
    $script:NetworkReachable = $false
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task   = $client.ConnectAsync($script:NetworkTarget, $script:NetworkPort)
        if ($task.Wait([System.TimeSpan]::FromSeconds(3))) {
            $script:NetworkReachable = $client.Connected
        }
        $client.Dispose()
    }
    catch {
        $script:NetworkReachable = $false
    }
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

    # Discovery-scope variables aren't visible to It bodies, so re-declare
    # the network target here for runtime use.
    $script:NetworkTarget = 'badssl.com'
    $script:NetworkPort   = 443
}

Describe 'PS.SSL network integration (real TLS endpoint)' -Tag 'Integration', 'Network' -Skip:(-not $script:NetworkReachable) {

    Context 'Test-SSLProtocol against badssl.com:443' {

        BeforeAll {
            # Run the probe once and reuse - each call opens 6+ sockets and
            # performs a real TLS handshake per protocol enum value, which
            # is expensive and we don't want to hammer the public endpoint.
            $script:result = Test-SSLProtocol -ComputerName $script:NetworkTarget -Port $script:NetworkPort
        }

        It 'Returns a PSCustomObject' {
            $script:result | Should -BeOfType ([pscustomobject])
        }

        It 'Echoes ComputerName and Port to the output object verbatim' {
            $script:result.ComputerName | Should -Be $script:NetworkTarget
            $script:result.Port         | Should -Be $script:NetworkPort
        }

        It 'Populates the negotiated KeyLength as a positive integer' {
            $script:result.KeyLength | Should -BeGreaterThan 0
        }

        It 'Populates SignatureAlgorithm with a non-empty string' {
            $script:result.SignatureAlgorithm | Should -Not -BeNullOrEmpty
        }

        It 'Exposes the remote certificate as an X509Certificate2' {
            $script:result.Certificate | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
        }

        It 'Reports at least one modern TLS protocol (Tls12 or Tls13) as supported' {
            $modernProtocols = @('Tls12', 'Tls13') | Where-Object {
                $script:result.PSObject.Properties.Name -contains $_
            }
            $modernProtocols.Count | Should -BeGreaterThan 0

            $supportedModern = $modernProtocols | Where-Object { $script:result.$_ -eq $true }
            $supportedModern.Count | Should -BeGreaterThan 0
        }

        It 'Encodes each probed protocol as a boolean property' {
            # Function iterates [SslProtocols] enum, skipping Default/None.
            # Every property added by the probe loop must be $true or $false.
            $protocolProps = $script:result.PSObject.Properties |
                Where-Object { $_.Name -notin 'ComputerName', 'Port', 'KeyLength', 'KeyExchange',
                                              'HashAlgorithm', 'SignatureAlgorithm', 'Certificate' }
            $protocolProps.Count | Should -BeGreaterThan 0
            foreach ($p in $protocolProps) {
                $p.Value | Should -BeOfType ([bool])
            }
        }
    }

    Context 'Test-SSLProtocol accepts pipeline input' {

        It 'Accepts -ComputerName from the pipeline' {
            $result = $script:NetworkTarget | Test-SSLProtocol -Port $script:NetworkPort
            $result              | Should -Not -BeNullOrEmpty
            $result.ComputerName | Should -Be $script:NetworkTarget
        }
    }

    Context 'Get-RemoteSSLCertificate against badssl.com' {

        BeforeAll {
            $script:remoteCert = Get-RemoteSSLCertificate -ComputerName $script:NetworkTarget -Port $script:NetworkPort
        }

        It 'Returns an X509Certificate2' {
            $script:remoteCert | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
        }

        It 'Populates Subject with a non-empty string' {
            $script:remoteCert.Subject | Should -Not -BeNullOrEmpty
        }

        It 'Returns a currently-valid certificate (NotAfter is in the future)' {
            $script:remoteCert.NotAfter | Should -BeOfType ([datetime])
            $script:remoteCert.NotAfter | Should -BeGreaterThan (Get-Date)
        }

        It 'Accepts -ComputerName from the pipeline' {
            $result = $script:NetworkTarget | Get-RemoteSSLCertificate -Port $script:NetworkPort
            $result         | Should -Not -BeNullOrEmpty
            $result.Subject | Should -Not -BeNullOrEmpty
        }

        It 'Returns one certificate per host when given multiple -ComputerName values' {
            $hosts = @($script:NetworkTarget, $script:NetworkTarget)
            $results = Get-RemoteSSLCertificate -ComputerName $hosts -Port $script:NetworkPort
            $results.Count | Should -Be 2
            $results | ForEach-Object {
                $_ | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
            }
        }
    }

    Context 'Get-RemoteSSLCertificate intentionally bypasses validation' {

        # SECURITY contract test: Get-RemoteSSLCertificate documents that it
        # accepts any server certificate so operators can inspect expired,
        # self-signed, and otherwise invalid certs. expired.badssl.com serves
        # a cert with NotAfter in the past; if a future change re-enables
        # validation, AuthenticateAsClient will throw and this test will fail
        # loudly. See the SECURITY note in Get-RemoteSSLCertificate's help.

        It 'Retrieves an expired certificate without throwing' {
            $expiredHost = 'expired.badssl.com'
            $cert = Get-RemoteSSLCertificate -ComputerName $expiredHost -Port 443
            $cert           | Should -BeOfType ([System.Security.Cryptography.X509Certificates.X509Certificate2])
            $cert.NotAfter  | Should -BeLessThan (Get-Date)
        }
    }
}
