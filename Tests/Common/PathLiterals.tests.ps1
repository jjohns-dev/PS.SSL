BeforeDiscovery {
    # One TestCase per Public/*.ps1 so failures point at the specific file.
    $publicDir = Join-Path -Path (Split-Path -Path $env:BHPSModuleManifest -Parent) -ChildPath 'Public'
    $script:PublicFileCases = foreach ($file in (Get-ChildItem -Path $publicDir -Filter '*.ps1' -File)) {
        @{ File = $file.Name; FullName = $file.FullName }
    }
}

Describe -Name 'Public function path literals' -Fixture {

    # PowerShell on Linux/macOS treats '\' as a literal filename character, not
    # a path separator. A backslash following $HOME, $PSScriptRoot, $PWD, or
    # $TestDrive in a string literal is almost always a Windows-ism that breaks
    # on cross-platform runners. Static scan beats per-instance tests.
    It -Name 'does not embed backslash after $HOME / $PSScriptRoot / $PWD / $TestDrive in <File>' -TestCases $PublicFileCases -Test {
        param($File, $FullName)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref] $null, [ref] $null)
        $offenders = $ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
                $node.Extent.Text -match '\$(HOME|PSScriptRoot|PWD|TestDrive)\\'
            }, $true)
        $offenders | Should -BeNullOrEmpty -Because (
            'found backslash-joined path literal(s): ' + (($offenders | ForEach-Object -Process { $_.Extent.Text }) -join '; ')
        )
    }
}
