[CmdletBinding()]
param(
    [ValidateSet('Status', 'Record')]
    [string]$Action = 'Status',

    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$LocalConfigPath,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')
. (Join-Path $PSScriptRoot 'pipeline-python.ps1')

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
if (-not $AsJson) {
    Write-PipelineConfigSummary -ResolvedConfig $resolved
}

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw 'Local application data directory is unavailable.'
}
$configuredStateRoot = [string]$config.generation.stateRoot
if ([string]::IsNullOrWhiteSpace($configuredStateRoot)) {
    $stateRoot = Join-Path $localAppData 'Codex\aem-watch-resource-pipeline\state'
}
elseif ([System.IO.Path]::IsPathRooted($configuredStateRoot)) {
    $stateRoot = [System.IO.Path]::GetFullPath($configuredStateRoot)
}
else {
    $stateRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $localAppData $configuredStateRoot)
    )
}

$uiProject = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path ([string]$config.paths.uiProject)
$translationTable = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path ([string]$config.paths.translationTable)
$resourceRoot = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path ([string]$config.paths.resourceRoot)
$requiredOutputs = @(
    $config.generation.generatedFiles | ForEach-Object {
        Resolve-PipelineProjectPath -ProjectRoot $project -Path ([string]$_)
    }
)

$python = Resolve-PipelinePython -Config $config `
    -ResolvedProjectRoot $project
$stateScript = Join-Path $PSScriptRoot 'resource_generation_state.py'
if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
    throw "Resource state helper not found: $stateScript"
}

$diagnosticRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) 'codex-aem-watch-resource'
$jobDirectory = Join-Path $diagnosticRoot 'jobs'
[System.IO.Directory]::CreateDirectory($jobDirectory) | Out-Null
$jobPath = Join-Path $jobDirectory (
    'state-' + [guid]::NewGuid().ToString('N') + '.json'
)
$job = [ordered]@{
    projectRoot = $project
    resourceRoot = $resourceRoot
    uiProject = $uiProject
    translationTable = $translationTable
    requiredOutputs = @($requiredOutputs)
    stateRoot = $stateRoot
    identity = [ordered]@{
        application = [string]$config.project.application
        board = [string]$config.project.board
        resolution = [string]$config.project.resolution
    }
}
[System.IO.File]::WriteAllText(
    $jobPath,
    ($job | ConvertTo-Json -Depth 20),
    (New-Object System.Text.UTF8Encoding($false))
)

try {
    $arguments = @($python.PrefixArguments)
    $arguments += @(
        '-B',
        $stateScript,
        '--job',
        $jobPath,
        '--action',
        $Action.ToLowerInvariant()
    )
    $global:LASTEXITCODE = 0
    $jsonOutput = & $python.Path @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Resource state helper failed with exit code $LASTEXITCODE."
    }
    $json = $jsonOutput -join [Environment]::NewLine
    $result = $json | ConvertFrom-Json

    if ($AsJson) {
        Write-Output $json
        return
    }

    Write-Output "RESOURCE_STATE=$($result.status)"
    Write-Output "RESOURCE_GENERATION_REQUIRED=$($result.generationRequired)"
    Write-Output "RESOURCE_STATE_FILE=$($result.stateFile)"
    Write-Output "RESOURCE_INPUT_DIGEST=$($result.inputDigest)"
    Write-Output "RESOURCE_INPUT_COUNT=$($result.inputCount)"
    foreach ($reason in @($result.reasons)) {
        Write-Output "RESOURCE_REASON=$reason"
    }
    foreach ($inputPath in @($result.changedInputs)) {
        Write-Output "RESOURCE_CHANGED_INPUT=$inputPath"
    }
    foreach ($outputPath in @($result.outputProblems)) {
        Write-Output "RESOURCE_OUTPUT_PROBLEM=$outputPath"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.stateError)) {
        Write-Output "RESOURCE_STATE_ERROR=$($result.stateError)"
    }
}
finally {
    if (Test-Path -LiteralPath $jobPath -PathType Leaf) {
        Remove-Item -LiteralPath $jobPath -Force
    }
}
