BeforeDiscovery {
    if (-not (Get-Module -Name $env:BHProjectName)) {
        Import-Module -Name $env:BHPSModuleManifest -ErrorAction 'Stop' -Force
    }
}

Describe -Name 'PS.SSL module loader' -Fixture {

    It -Name 'imports without error in the current environment' -Test {
        Get-Module -Name $env:BHProjectName -All | Remove-Module -Force -ErrorAction 'SilentlyContinue'
        { Import-Module -Name $env:BHPSModuleManifest -Force } | Should -Not -Throw
    }

    It -Name 'tolerates the absence of an optional Private/ directory at import time' -Test {
        # The loader skips a missing Private/ rather than letting Get-ChildItem
        # throw on Linux/macOS, where the wildcard path is evaluated more
        # strictly than on Windows. Stage a Private-less copy of the module
        # into TestDrive and assert Import-Module does not throw.
        $moduleRoot = Split-Path -Path $env:BHPSModuleManifest -Parent
        $stage = Join-Path -Path $TestDrive -ChildPath $env:BHProjectName
        New-Item -Path $stage -ItemType 'Directory' -Force | Out-Null
        Copy-Item -Path (Join-Path -Path $moduleRoot -ChildPath ('{0}.psd1' -f $env:BHProjectName)) -Destination $stage
        Copy-Item -Path (Join-Path -Path $moduleRoot -ChildPath ('{0}.psm1' -f $env:BHProjectName)) -Destination $stage
        Copy-Item -Path (Join-Path -Path $moduleRoot -ChildPath 'Public') -Destination $stage -Recurse
        (Test-Path -Path (Join-Path -Path $stage -ChildPath 'Private') -PathType Container) | Should -BeFalse

        $stagedManifest = Join-Path -Path $stage -ChildPath ('{0}.psd1' -f $env:BHProjectName)
        Get-Module -Name $env:BHProjectName -All | Remove-Module -Force -ErrorAction 'SilentlyContinue'
        { Import-Module -Name $stagedManifest -Force } | Should -Not -Throw
    }

    It -Name 'does not warn about missing openssl when openssl is on PATH' -Skip:($IsWindows) -Test {
        # Linux/macOS branch checks @('/usr/bin','/usr/sbin','/sbin','/bin').
        # Hosted CI runners ship openssl in /usr/bin so this branch should be quiet.
        # Stream redirection (3>&1) is used because Import-Module's
        # -WarningVariable does not capture warnings from a module's .psm1 body.
        Get-Module -Name $env:BHProjectName -All | Remove-Module -Force -ErrorAction 'SilentlyContinue'
        $warnings = & { Import-Module -Name $env:BHPSModuleManifest -Force } 3>&1 |
            Where-Object -FilterScript { $_ -is [System.Management.Automation.WarningRecord] }
        ($warnings | Where-Object -FilterScript { $_.Message -match 'Openssl not found' }) | Should -BeNullOrEmpty
    }
}
