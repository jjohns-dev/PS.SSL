Version 5

# PSake makes variables declared here available in other scriptblocks
# Note: variables are set via Set-Variable rather than `$x = ...` so that
# PSScriptAnalyzer's PSUseDeclaredVarsMoreThanAssignments rule does not
# false-positive on them. PSSA can't follow psake's runtime hoisting of
# Properties-block variables into Task scriptblocks; Set-Variable is the
# documented psake workaround.
Properties {
    Set-Variable -Name 'ProjectRoot' -Value $env:BHProjectPath
    if (-not $ProjectRoot) {
        Set-Variable -Name 'ProjectRoot' -Value $PSScriptRoot
    }

    Set-Variable -Name 'Timestamp' -Value (Get-Date -UFormat '%Y%m%d-%H%M%S')
    Set-Variable -Name 'lines' -Value '----------------------------------------------------------------------'

    # Pester
    # Cross-platform tests use the conventional *.Tests.ps1 suffix. Windows-only
    # tests (Loader.Tests.windows.ps1) follow the SecurityTools pattern: the
    # filename carries the platform gate so the build can pick them up only on
    # Windows runners without per-test $IsWindows guards.
    $crossPlatformTests = Get-ChildItem "$ProjectRoot/Tests/*/*Tests.ps1" |
        Where-Object { $_.Name -notmatch '\.Tests\.windows\.ps1$' }
    if ($IsWindows) {
        $windowsTests = Get-ChildItem "$ProjectRoot/Tests/*/*.Tests.windows.ps1" -ErrorAction SilentlyContinue
        Set-Variable -Name 'TestScripts' -Value ($crossPlatformTests + $windowsTests)
    }
    else {
        Set-Variable -Name 'TestScripts' -Value $crossPlatformTests
    }
    Set-Variable -Name 'TestFile' -Value "Test-Unit_$($Timestamp).xml"

    # Script Analyzer
    # Valid values: 'Error', 'Warning', 'Any', 'None'.
    Set-Variable -Name 'ScriptAnalysisFailBuildOnSeverityLevel' -Value 'Error'
    Set-Variable -Name 'ScriptAnalyzerSettingsPath' -Value "$ProjectRoot/Build/PSScriptAnalyzerSettings.psd1"

    # Build
    Set-Variable -Name 'ArtifactFolder' -Value (Join-Path -Path $ProjectRoot -ChildPath 'Artifacts')

    # Staging
    Set-Variable -Name 'StagingFolder' -Value (Join-Path -Path $ProjectRoot -ChildPath 'Staging')
    Set-Variable -Name 'StagingModulePath' -Value (Join-Path -Path $StagingFolder -ChildPath $env:BHProjectName)
    Set-Variable -Name 'StagingModuleManifestPath' -Value (Join-Path -Path $StagingModulePath -ChildPath "$($env:BHProjectName).psd1")
}

# Define top-level tasks
Task 'Default' -depends 'Test'

# Show build variables
Task 'Init' {
    $lines

    Set-Location $ProjectRoot
    'Build System Details:'
    Get-Item ENV:BH*
    "`n"
}

# Setup the Artifact and Staging folders
Task 'Setup' -depends 'Init' {
    $lines

    $foldersToSetup = @(
        $ArtifactFolder
        $StagingFolder
    )

    # Remove folders
    foreach ($folderPath in $foldersToSetup) {
        Remove-Item -Path $folderPath -Recurse -Force -ErrorAction 'SilentlyContinue'
        New-Item -Path $folderPath -ItemType 'Directory' -Force | Out-String | Write-Verbose
    }
}

# Stage the module layout for packaging.
# Copies the public functions, manifest, root module, README, and (when
# present) private helpers into $StagingModulePath. The module is shipped
# as the original multi-file layout rather than being combined into a
# single .psm1 - the loader in PS.SSL.psm1 dot-sources each file at
# import time, which keeps file-level debugger breakpoints and stack
# traces meaningful for consumers.
Task 'CombineFunctionsAndStage' -depends 'Setup' {
    $lines

    # Create folders
    New-Item -Path $StagingFolder -ItemType 'Directory' -Force | Out-String | Write-Verbose
    New-Item -Path $StagingModulePath -ItemType 'Directory' -Force | Out-String | Write-Verbose

    # Copy required folders and files.
    # 'Private' is optional (no private helpers yet) so it is skipped when
    # absent. All other entries are required; an empty required directory is
    # treated as a build failure because it usually means files were lost or a
    # checkout went wrong.
    $requiredPaths = @(
        Join-Path -Path $ProjectRoot -ChildPath 'Public'
        Join-Path -Path $ProjectRoot -ChildPath 'README.md'
        Join-Path -Path $ProjectRoot -ChildPath ($env:BHProjectName + '.psd1')
        Join-Path -Path $ProjectRoot -ChildPath ($env:BHProjectName + '.psm1')
    )
    $optionalPaths = @(
        Join-Path -Path $ProjectRoot -ChildPath 'Private'
    )

    foreach ($p in $requiredPaths) {
        if (-not (Test-Path -Path $p)) {
            throw "Required build input not found: $p"
        }
        if ((Test-Path -Path $p -PathType 'Container') -and
            -not (Get-ChildItem -Path $p -File -Recurse -ErrorAction 'SilentlyContinue')) {
            throw "Required build input directory is empty: $p"
        }
    }

    $pathsToCopy = $requiredPaths + ($optionalPaths | Where-Object { Test-Path -Path $_ })
    Copy-Item -Path $pathsToCopy -Destination $StagingModulePath -Recurse
}

# Import new module
Task 'ImportStagingModule' -depends 'Init', 'CombineFunctionsAndStage' {
    $lines
    Write-Output "Reloading staged module from path: [$StagingModulePath]`n"

    # Reload module
    if (Get-Module -Name $env:BHProjectName) {
        Remove-Module -Name $env:BHProjectName -Force
    }

    Import-Module -Name $StagingModulePath -ErrorAction 'Stop' -Force
}

# Run PSScriptAnalyzer against code to ensure quality and best practices are used
Task 'Analyze' -depends 'ImportStagingModule' {
    $lines
    Write-Output "Running PSScriptAnalyzer on path: [$StagingModulePath]`n"

    $Results = Invoke-ScriptAnalyzer -Path $StagingModulePath -Recurse -Settings $ScriptAnalyzerSettingsPath -Verbose:$VerbosePreference
    $Results | Select-Object 'RuleName', 'Severity', 'ScriptName', 'Line', 'Message' | Format-List

    switch ($ScriptAnalysisFailBuildOnSeverityLevel) {
        'None' {
            return
        }
        'Error' {
            Assert -conditionToCheck (
                ($Results | Where-Object 'Severity' -eq 'Error').Count -eq 0
            ) -failureMessage 'One or more ScriptAnalyzer errors were found. Build cannot continue!'
        }
        'Warning' {
            Assert -conditionToCheck (
                ($Results | Where-Object {
                    $_.Severity -eq 'Warning' -or $_.Severity -eq 'Error'
                }).Count -eq 0) -failureMessage 'One or more ScriptAnalyzer warnings were found. Build cannot continue!'
        }
        default {
            Assert -conditionToCheck ($analysisResult.Count -eq 0) -failureMessage 'One or more ScriptAnalyzer issues were found. Build cannot continue!'
        }
    }
}

# Run Pester tests
# Unit tests: verify inputs / outputs / expected execution path
# Misc tests: verify manifest data, check comment-based help exists
Task 'Test' -depends 'ImportStagingModule' {
    $lines

    # Gather test results. Store them in a variable and file
    $TestFilePath = Join-Path -Path $ArtifactFolder -ChildPath $TestFile

    # create a new configuration with our settings
    $PesterConfig = New-PesterConfiguration
    $PesterConfig.TestResult.OutputFormat = 'JUnitXml'
    $PesterConfig.TestResult.OutputPath = $TestFilePath
    $PesterConfig.TestResult.Enabled = $true
    $PesterConfig.Run.PassThru = $true
    $PesterConfig.Run.Path = $TestScripts
    #$PesterConfig.Output.Verbosity = 'Diagnostic'

    # Exclude tests tagged 'Network' from the gating build. These hit a real
    # third-party TLS endpoint (badssl.com) and have proven flaky on CI
    # runners - connectivity can pass the Discovery-time probe and still
    # fail moments later when the test itself runs, intermittently failing
    # otherwise-green builds. Run them explicitly (e.g.
    # -Tag Network) when validating network connectivity locally.
    $PesterConfig.Filter.ExcludeTag = 'Network'

    $TestResults = Invoke-Pester -Configuration $PesterConfig

    # Fail build on any non-passing result. Discovery errors attach to the
    # container rather than a test, leaving FailedCount at 0.
    if ($TestResults.Result -ne 'Passed') {
        Write-Error "Pester result '$($TestResults.Result)' with '$($TestResults.FailedCount)' failed test(s), build failed"
    }
}

# Create a versioned zip file of all staged files
# NOTE: Admin Rights are needed if you run this locally
Task 'CreateBuildArtifact' -depends 'Init' {
    $lines

    # Create /Release folder
    New-Item -Path $ArtifactFolder -ItemType 'Directory' -Force | Out-String | Write-Verbose

    # Get current manifest version
    try {
        $manifest = Test-ModuleManifest -Path $StagingModuleManifestPath -ErrorAction 'Stop'
        [Version]$manifestVersion = $manifest.Version

    }
    catch {
        throw "Could not get manifest version from [$StagingModuleManifestPath]"
    }

    # Create zip file
    try {
        $releaseFilename = "$($env:BHProjectName)-v$($manifestVersion.ToString()).zip"
        $releasePath = Join-Path -Path $ArtifactFolder -ChildPath $releaseFilename
        Write-Output "Creating release artifact [$releasePath] using manifest version [$manifestVersion]"
        Compress-Archive -Path "$StagingFolder/*" -DestinationPath $releasePath -Force -Verbose -ErrorAction 'Stop'
    }
    catch {
        throw "Could not create release artifact [$releasePath] using manifest version [$manifestVersion]"
    }

    Write-Output "`nFINISHED: Release artifact creation."
}

# cleanup dirs and files when finished
Task 'Cleanup' {
    $lines

    Write-Output 'Cleaning leftover/unneeded artifacts'

    # cleanup
    Remove-Item -Path $ArtifactFolder -Recurse -Force -ErrorAction 'SilentlyContinue'
    Remove-Item -Path $StagingFolder -Recurse -Force -ErrorAction 'SilentlyContinue'
}