[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$LocalConfigPath,

    [switch]$AllowMissingGeneratedFiles,
    [switch]$AllowUnchangedResources,
    [switch]$ForceResourceGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')
. (Join-Path $PSScriptRoot 'pipeline-python.ps1')

function Resolve-ConfiguredProjectPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedProjectRoot
    )

    return @(
        $Paths | ForEach-Object {
            Resolve-PipelineProjectPath `
                -ProjectRoot $ResolvedProjectRoot `
                -Path ([string]$_)
        }
    )
}

$commonArguments = @{}
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $commonArguments.ProjectRoot = $ProjectRoot
}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $commonArguments.ConfigPath = $ConfigPath
}
if (-not [string]::IsNullOrWhiteSpace($LocalConfigPath)) {
    $commonArguments.LocalConfigPath = $LocalConfigPath
}

$resolved = Resolve-AemWatchPipelineConfig @commonArguments
$config = $resolved.Config
$project = $resolved.ProjectRoot
Write-PipelineConfigSummary -ResolvedConfig $resolved

$changedOnly = [bool](
    $config.execution.regenerateResourcesOnlyWhenChanged
)
if ($changedOnly -and -not $ForceResourceGeneration) {
    $stateArguments = $commonArguments.Clone()
    $stateArguments.Action = 'Status'
    $stateArguments.AsJson = $true
    $stateOutput = & (
        Join-Path $PSScriptRoot 'resource-generation-state.ps1'
    ) @stateArguments
    $resourceState = ($stateOutput -join [Environment]::NewLine) |
        ConvertFrom-Json
    foreach ($reason in @($resourceState.reasons)) {
        Write-Output "RESOURCE_GENERATION_REASON=$reason"
    }
    if (-not [bool]$resourceState.generationRequired) {
        Write-Output 'RESULT=SKIPPED'
        Write-Output 'SKIP_REASON=RESOURCE_INPUTS_AND_OUTPUTS_UNCHANGED'
        Write-Output "RESOURCE_STATE_FILE=$($resourceState.stateFile)"
        return
    }
}
elseif ($ForceResourceGeneration) {
    Write-Output 'RESOURCE_GENERATION_FORCED=true'
}

$editor = Resolve-PipelineToolPath -ProjectRoot $project `
    -Path ([string]$config.paths.uiEditor)
$uiProject = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path ([string]$config.paths.uiProject)

$snapshotRoots = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.snapshotRoots |
            ForEach-Object { [string]$_ }
    )
$snapshotFiles = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.snapshotFiles |
            ForEach-Object { [string]$_ }
    )
$requiredOutputs = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.generatedFiles |
            ForEach-Object { [string]$_ }
    )
$ephemeralFiles = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.ephemeralFiles |
            ForEach-Object { [string]$_ }
    )
$normalizeChangedTextFiles = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.normalizeChangedTextFiles |
            ForEach-Object { [string]$_ }
    )
$preserveInputFiles = Resolve-ConfiguredProjectPaths `
    -ResolvedProjectRoot $project `
    -Paths @(
        $config.generation.preserveInputFiles |
            ForEach-Object { [string]$_ }
    )
$preserveGeneratedSuffixes = @(
    foreach ($entry in @($config.generation.preserveGeneratedSuffixes)) {
        if ($null -eq $entry) { continue }
        $marker = [string]$entry.marker
        if ([string]::IsNullOrWhiteSpace($marker)) {
            throw 'generation.preserveGeneratedSuffixes marker cannot be empty.'
        }
        [ordered]@{
            path = Resolve-PipelineProjectPath `
                -ProjectRoot $project `
                -Path ([string]$entry.path)
            marker = $marker
        }
    }
)

$python = Resolve-PipelinePython -Config $config `
    -ResolvedProjectRoot $project
$generator = Join-Path $PSScriptRoot 'generate_ui_resources.py'
if (-not (Test-Path -LiteralPath $generator -PathType Leaf)) {
    throw "UI resource generator not found: $generator"
}

$diagnosticRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) 'codex-aem-watch-resource'
$jobDirectory = Join-Path $diagnosticRoot 'jobs'
[System.IO.Directory]::CreateDirectory($jobDirectory) | Out-Null
$jobPath = Join-Path $jobDirectory (
    'generate-' + [guid]::NewGuid().ToString('N') + '.json'
)

$commands = $config.generation.editorCommands
$job = [ordered]@{
    projectRoot = $project
    editor = $editor
    uiProject = $uiProject
    snapshotRoots = @($snapshotRoots)
    snapshotFiles = @($snapshotFiles)
    requiredOutputs = @($requiredOutputs)
    ephemeralFiles = @($ephemeralFiles)
    editorTemporaryFiles = $config.generation.editorTemporaryFiles
    normalizeChangedTextFiles = @($normalizeChangedTextFiles)
    preserveInputFiles = @($preserveInputFiles)
    preserveGeneratedSuffixes = @($preserveGeneratedSuffixes)
    allowedChangePatterns = @(
        $config.generation.allowedChangePatterns |
            ForEach-Object { [string]$_ }
    )
    commands = [ordered]@{
        open = [int]$commands.open
        save = [int]$commands.save
        generateQualityHigh = [int]$commands.generateQualityHigh
    }
    timeoutSeconds = [int]$config.generation.timeoutSeconds
    stableSeconds = [int]$config.generation.stableSeconds
    idleFailureSeconds = [int]$config.generation.idleFailureSeconds
    diagnosticRoot = $diagnosticRoot
    allowMissingBefore = [bool]$AllowMissingGeneratedFiles
    allowUnchanged = [bool]$AllowUnchangedResources
    keepBackupOnSuccess = $false
}

$json = $job | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText(
    $jobPath,
    $json,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Output "PYTHON=$($python.Path)"
Write-Output "PYTHON_SOURCE=$($python.Source)"
Write-Output "UI_EDITOR=$editor"
Write-Output "UI_PROJECT=$uiProject"
Write-Output "UI_GENERATION_MODE=$($config.tools.uiEditorGenerationMode)"
Write-Output "TRANSACTION_ROOTS=$($snapshotRoots -join ';')"
Write-Output "DIAGNOSTIC_ROOT=$diagnosticRoot"

try {
    $arguments = @()
    $arguments += @($python.PrefixArguments)
    $arguments += @('-B', $generator, '--job', $jobPath)
    $global:LASTEXITCODE = 0
    & $python.Path @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "UI resource generation failed with exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $jobPath -PathType Leaf) {
        Remove-Item -LiteralPath $jobPath -Force
    }
}
