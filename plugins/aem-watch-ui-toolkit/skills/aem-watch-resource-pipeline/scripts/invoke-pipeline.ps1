[CmdletBinding()]
param(
    [ValidateSet(
        'ResourceEnvironment',
        'TranslationEnvironment',
        'ResourcePrepare',
        'TranslationPrepare',
        'TranslationDryRun',
        'TranslationApply',
        'ResourcePre',
        'ResourceStatus',
        'Generate',
        'FinalizeResources',
        'Post'
    )]
    [string]$Action = 'ResourceEnvironment',

    [string]$ProjectRoot,
    [string]$ManifestPath,
    [string]$ConfigPath,
    [string]$LocalConfigPath,

    [switch]$RegisterWps,
    [switch]$RepairManualDeclarations,
    [switch]$AllowMissingGeneratedFiles,
    [switch]$AllowUnchangedResources,
    [switch]$ForceResourceGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    throw 'All pipeline actions require an explicit -ConfigPath.'
}

function Get-CommonArguments {
    $arguments = @{}
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $arguments.ProjectRoot = $ProjectRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $arguments.ConfigPath = $ConfigPath
    }
    if (-not [string]::IsNullOrWhiteSpace($LocalConfigPath)) {
        $arguments.LocalConfigPath = $LocalConfigPath
    }
    return $arguments
}

function Assert-Manifest {
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw "Action '$Action' requires -ManifestPath."
    }
}

function Invoke-CheckedScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    $global:LASTEXITCODE = 0
    & $Path @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Pipeline step failed with exit code ${LASTEXITCODE}: $Path"
    }
}

function Invoke-Environment {
    param([ValidateSet('Resource', 'Translation')][string]$Capability)

    $arguments = Get-CommonArguments
    $arguments.Capability = $Capability
    Invoke-CheckedScript -Path (
        Join-Path $PSScriptRoot 'test-environment.ps1'
    ) -Arguments $arguments
}

function Invoke-Translation {
    param([bool]$ApplyChanges)

    Assert-Manifest
    $arguments = Get-CommonArguments
    $arguments.ManifestPath = $ManifestPath
    if ($ApplyChanges) {
        $arguments.Apply = $true
    }
    if ($RegisterWps) {
        $arguments.RegisterWps = $true
    }
    Invoke-CheckedScript -Path (
        Join-Path $PSScriptRoot 'update-translations.ps1'
    ) -Arguments $arguments
}

function Invoke-Validation {
    param(
        [ValidateSet('Pre', 'Post')]
        [string]$Phase,

        [switch]$RepairConfiguredDeclarations
    )

    Assert-Manifest
    $arguments = Get-CommonArguments
    $arguments.ManifestPath = $ManifestPath
    $arguments.Phase = $Phase
    if (
        $Phase -eq 'Post' -and
        ($RepairManualDeclarations -or $RepairConfiguredDeclarations)
    ) {
        $arguments.RepairManualDeclarations = $true
    }
    Invoke-CheckedScript -Path (
        Join-Path $PSScriptRoot 'validate-ui-case.ps1'
    ) -Arguments $arguments
}

function Invoke-ResourceState {
    param([ValidateSet('Status', 'Record')][string]$StateAction)

    $arguments = Get-CommonArguments
    $arguments.Action = $StateAction
    Invoke-CheckedScript -Path (
        Join-Path $PSScriptRoot 'resource-generation-state.ps1'
    ) -Arguments $arguments
}

function Invoke-Generation {
    $arguments = Get-CommonArguments
    if ($AllowMissingGeneratedFiles) {
        $arguments.AllowMissingGeneratedFiles = $true
    }
    if ($AllowUnchangedResources) {
        $arguments.AllowUnchangedResources = $true
    }
    if ($ForceResourceGeneration) {
        $arguments.ForceResourceGeneration = $true
    }
    Invoke-CheckedScript -Path (
        Join-Path $PSScriptRoot 'generate-ui-resources.ps1'
    ) -Arguments $arguments
}

function Write-ResourceNextAction {
    $arguments = Get-CommonArguments
    $resolved = Resolve-AemWatchPipelineConfig @arguments
    $uiEditorPath = Resolve-PipelineToolPath `
        -ProjectRoot $resolved.ProjectRoot `
        -Path ([string]$resolved.Config.paths.uiEditor)
    $uiProjectPath = Resolve-PipelineProjectPath `
        -ProjectRoot $resolved.ProjectRoot `
        -Path ([string]$resolved.Config.paths.uiProject)
    Write-Output "NEXT_UI_EDITOR=$uiEditorPath"
    Write-Output "NEXT_UI_PROJECT=$uiProjectPath"
    Write-Output "NEXT_UI_MODE=$(
        $resolved.Config.tools.uiEditorGenerationMode
    )"
    Write-Output 'NEXT_ACTION=FinalizeResources'
}

function Invoke-FinalizeResources {
    Assert-Manifest
    Invoke-Environment -Capability 'Resource'
    Invoke-Generation
    Invoke-Validation -Phase 'Post' -RepairConfiguredDeclarations
    Invoke-ResourceState -StateAction 'Record'
}

switch ($Action) {
    'ResourceEnvironment' {
        Invoke-Environment -Capability 'Resource'
    }
    'TranslationEnvironment' {
        Invoke-Environment -Capability 'Translation'
    }
    'ResourcePrepare' {
        Invoke-Environment -Capability 'Resource'
        Invoke-Validation -Phase 'Pre'
        Write-ResourceNextAction
    }
    'TranslationPrepare' {
        Invoke-Environment -Capability 'Translation'
        Invoke-Translation -ApplyChanges $false
        Write-Output 'NEXT_ACTION=TranslationApply'
    }
    'TranslationDryRun' {
        Invoke-Environment -Capability 'Translation'
        Invoke-Translation -ApplyChanges $false
    }
    'TranslationApply' {
        Invoke-Environment -Capability 'Translation'
        Invoke-Translation -ApplyChanges $true
    }
    'ResourcePre' {
        Invoke-Validation -Phase 'Pre'
    }
    'ResourceStatus' {
        Invoke-ResourceState -StateAction 'Status'
    }
    'Generate' {
        Invoke-Generation
    }
    'FinalizeResources' {
        Invoke-FinalizeResources
    }
    'Post' {
        Invoke-Validation -Phase 'Post'
    }
}

Write-Output "ACTION=$Action"
Write-Output 'ACTION_RESULT=SUCCESS'
