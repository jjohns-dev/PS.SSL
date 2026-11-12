BeforeDiscovery {
    if (-not (Get-Module -Name $env:BHProjectName)) {
        Import-Module -Name $env:BHPSModuleManifest -ErrorAction 'Stop' -Force
    }

    # Walk every Public/*.ps1 and collect any OutputDirectory parameter whose
    # default value is a static expression. Each case becomes one It block so
    # the failure message points to the specific function and its default.
    $publicDir = Join-Path -Path (Split-Path -Path $env:BHPSModuleManifest -Parent) -ChildPath 'Public'
    $script:DefaultDirCases = foreach ($file in (Get-ChildItem -Path $publicDir -Filter '*.ps1' -File)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $null)
        $params = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ParameterAst] -and
                $node.Name.VariablePath.UserPath -eq 'OutputDirectory' -and
                $null -ne $node.DefaultValue
            }, $true)
        foreach ($p in $params) {
            @{
                File        = $file.Name
                DefaultText = $p.DefaultValue.Extent.Text
            }
        }
    }
}

Describe -Name 'Public function default OutputDirectory paths' -Fixture {

    # Asserts the resolved default points at $HOME/Desktop on the current OS.
    # Catches stray '\' literals that Windows tolerates but Linux/macOS treat
    # as a single filename character (e.g. /home/runner\Desktop).
    It -Name '<File> default resolves to $HOME/Desktop on the current OS' -TestCases $DefaultDirCases -Test {
        param($File, $DefaultText)
        $resolved = & ([System.Management.Automation.ScriptBlock]::Create($DefaultText))
        (Split-Path -Path $resolved -Leaf)   | Should -Be 'Desktop'
        (Split-Path -Path $resolved -Parent) | Should -Be $HOME
    }
}
