BeforeDiscovery {
    if (-not (Get-Module -Name $env:BHProjectName)) {
        Import-Module -Name $env:BHPSModuleManifest -ErrorAction 'Stop' -Force
    }
}

Describe -Name 'Test-PrivateKeyCertMatch' -Fixture {

    Context -Name 'parameter validation' -Fixture {

        It -Name 'rejects -PrivateKeyPath that does not have a .key or .pem extension' -Test {
            $wrongExt = Join-Path -Path $TestDrive -ChildPath 'notakey.txt'
            Set-Content -Path $wrongExt -Value 'placeholder'
            $cert = Join-Path -Path $TestDrive -ChildPath 'cert.pem'
            Set-Content -Path $cert -Value 'placeholder'

            { Test-PrivateKeyCertMatch -PrivateKeyPath $wrongExt -CertificatePath $cert } |
                Should -Throw -ExpectedMessage '*PrivateKeyPath*'
        }

        It -Name 'rejects -CertificatePath that does not have a .crt, .cer, or .pem extension' -Test {
            $key = Join-Path -Path $TestDrive -ChildPath 'key.key'
            Set-Content -Path $key -Value 'placeholder'
            $wrongExt = Join-Path -Path $TestDrive -ChildPath 'notacert.txt'
            Set-Content -Path $wrongExt -Value 'placeholder'

            { Test-PrivateKeyCertMatch -PrivateKeyPath $key -CertificatePath $wrongExt } |
                Should -Throw -ExpectedMessage '*CertificatePath*'
        }

        It -Name 'rejects -PrivateKeyPath that does not exist' -Test {
            $cert = Join-Path -Path $TestDrive -ChildPath 'cert.pem'
            Set-Content -Path $cert -Value 'placeholder'
            $missing = Join-Path -Path $TestDrive -ChildPath 'missing.key'

            { Test-PrivateKeyCertMatch -PrivateKeyPath $missing -CertificatePath $cert } |
                Should -Throw -ExpectedMessage '*PrivateKeyPath*'
        }

        It -Name 'rejects -CertificatePath that does not exist' -Test {
            $key = Join-Path -Path $TestDrive -ChildPath 'key.key'
            Set-Content -Path $key -Value 'placeholder'
            $missing = Join-Path -Path $TestDrive -ChildPath 'missing.pem'

            { Test-PrivateKeyCertMatch -PrivateKeyPath $key -CertificatePath $missing } |
                Should -Throw -ExpectedMessage '*CertificatePath*'
        }
    }
}
