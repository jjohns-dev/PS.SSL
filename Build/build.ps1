[CmdletBinding()]
param (
    [Parameter()]
    [ValidateSet('Default', 'Init', 'Setup', 'CombineFunctionsAndStage', 'ImportStagingModule', 'Analyze', 'Test', 'CreateBuildArtifact', 'Cleanup')]
    [System.String[]]
    $TaskList = 'Default',

    [Parameter()]
    [System.Collections.Hashtable]
    $Parameters,

    [Parameter()]
    [System.Collections.Hashtable]
    $Properties,

    [Parameter()]
    [Switch]
    $ResolveDependency
)

Write-Output "`nSTARTED TASKS: $($TaskList -join ',')`n"

Write-Output "`nPowerShell Version Information:"
$PSVersionTable

# Load dependencies
if ($PSBoundParameters.Keys -contains 'ResolveDependency') {
    # Install build dependencies from depend.psd1 via PSResourceGet.
    # TrustRepository: PSGallery registers as Trusted=False under PSResourceGet,
    # so the install would otherwise prompt and fail non-interactively.
    $psdependencyConfigPath = Join-Path -Path $PSScriptRoot -ChildPath 'depend.psd1'
    Write-Output "Checking / resolving module dependencies from [$psdependencyConfigPath]..."
    $data = Import-PowerShellDataFile -Path $psdependencyConfigPath
    foreach ($name in ($data.Keys | Where-Object { $_ -ne 'PSDependOptions' })) {
        Install-PSResource -Name $name -Version $data[$name] -Repository 'PSGallery' -TrustRepository -Scope 'CurrentUser' -ErrorAction 'Stop'
    }

    # Remove ResolveDependency PSBoundParameter ready for passthru to PSake
    $PSBoundParameters.Remove('ResolveDependency')
}
else {
    Write-Output "Skipping dependency check...`n" -ForegroundColor 'Yellow'
}

# Set build environment variables
$env:BHProjectPath = $PSScriptRoot | Split-Path -Parent
$manifestFile = Get-ChildItem -Path $env:BHProjectPath -Filter '*.psd1'
$env:BHProjectName = $manifestFile.BaseName
$env:BHPSModuleManifest = $manifestFile.FullName

# Execute PSake tasts
$invokePsakeParams = @{
    buildFile = (Join-Path -Path $env:BHProjectPath -ChildPath 'Build\build.psake.ps1')
    nologo    = $true
}
# Emit GitHub Actions workflow annotations (::error::, ::warning::) when
# running under Actions so PSScriptAnalyzer and Pester failures surface as
# inline PR annotations.
if ($env:GITHUB_ACTIONS -eq 'true') {
    $invokePsakeParams['OutputFormat'] = 'GitHubActions'
}
Invoke-psake @invokePsakeParams @PSBoundParameters

Write-Output "`nFINISHED TASKS: $($TaskList -join ',')"
exit ( [int](-not $psake.build_success) )
