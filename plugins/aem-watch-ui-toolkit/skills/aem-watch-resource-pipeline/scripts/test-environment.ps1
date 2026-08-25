[CmdletBinding()]
param(
    [ValidateSet('Resource', 'Translation')]
    [string]$Capability = 'Resource',

    [string]$ProjectRoot,
    [string]$ConfigPath,
    [string]$LocalConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')

$script:PassCount = 0
$script:FailureCount = 0
$script:WarningCount = 0

function Add-EnvironmentCheck {
    param(
        [bool]$Condition,
        [string]$Message,
        [string]$Hint
    )

    if ($Condition) {
        $script:PassCount++
        Write-Output "PASS $Message"
    }
    else {
        $script:FailureCount++
        Write-Output "FAIL $Message"
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            Write-Output "HINT $Hint"
        }
    }
}

function Add-EnvironmentWarning {
    param(
        [bool]$Condition,
        [string]$Message,
        [string]$Hint
    )

    if ($Condition) {
        $script:PassCount++
        Write-Output "PASS $Message"
    }
    else {
        $script:WarningCount++
        Write-Output "WARN $Message"
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            Write-Output "HINT $Hint"
        }
    }
}

$resolved = Resolve-AemWatchPipelineConfig -ProjectRoot $ProjectRoot `
    -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
$config = $resolved.Config
$project = $resolved.ProjectRoot
Write-PipelineConfigSummary -ResolvedConfig $resolved

if ($Capability -eq 'Resource') {
    $requiredFiles = [ordered]@{
        'UI project' = [string]$config.paths.uiProject
        'translation table' = [string]$config.paths.translationTable
        'include header' = [string]$config.paths.includeHeader
        'string map' = [string]$config.paths.stringMap
    }

    foreach ($pair in $requiredFiles.GetEnumerator()) {
        $path = Resolve-PipelineProjectPath `
            -ProjectRoot $project -Path $pair.Value
        Add-EnvironmentCheck -Condition (
            Test-Path -LiteralPath $path -PathType Leaf
        ) -Message "$($pair.Key) exists: $path" `
            -Hint 'Update the current branch project profile.'
    }

    $boardResourcePath = Resolve-PipelineProjectPath -ProjectRoot $project `
        -Path ([string]$config.paths.boardResourceRoot)
    Add-EnvironmentCheck -Condition (
        Test-Path -LiteralPath $boardResourcePath -PathType Container
    ) -Message "board resource directory exists: $boardResourcePath" `
        -Hint 'Check project.board and paths.boardResourceRoot.'

    $uiEditorPath = Resolve-PipelineToolPath -ProjectRoot $project `
        -Path ([string]$config.paths.uiEditor)
    Add-EnvironmentCheck -Condition (
        Test-Path -LiteralPath $uiEditorPath -PathType Leaf
    ) -Message "UI Editor exists: $uiEditorPath" `
        -Hint 'Configure paths.uiEditor in the project profile.'

    $pythonCandidates = @()
    $configuredPython = [string]$config.tools.pythonExecutable
    if (-not [string]::IsNullOrWhiteSpace($configuredPython)) {
        $pythonCandidates += Resolve-PipelineToolPath `
            -ProjectRoot $project -Path $configuredPython
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $pythonCandidates += Join-Path $env:USERPROFILE (
            '.cache\codex-runtimes\codex-primary-runtime\' +
            'dependencies\python\python.exe'
        )
    }
    $pythonCommand = Get-Command 'python.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pythonCommand) {
        $pythonCandidates += $pythonCommand.Source
    }
    $pyCommand = Get-Command 'py.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pyCommand) {
        $pythonCandidates += $pyCommand.Source
    }
    $pythonPath = @(
        $pythonCandidates | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } | Select-Object -First 1
    )
    Add-EnvironmentCheck -Condition ($pythonPath.Count -eq 1) `
        -Message "Python 3 runtime exists: $($pythonPath -join '')" `
        -Hint (
            'Configure tools.pythonExecutable in ' +
            '%USERPROFILE%\.codex\config\' +
            'aem-watch-resource-pipeline.local.json.'
        )

    Write-Output "UI_EDITOR=$uiEditorPath"
    Write-Output "UI_GENERATION_MODE=$($config.tools.uiEditorGenerationMode)"
}
else {
    $translationTable = Resolve-PipelineProjectPath -ProjectRoot $project `
        -Path ([string]$config.paths.translationTable)
    Add-EnvironmentCheck -Condition (
        Test-Path -LiteralPath $translationTable -PathType Leaf
    ) -Message "translation table exists: $translationTable" `
        -Hint 'Check paths.translationTable in the current branch profile.'
}

$wpsRoots = @(
    $config.tools.wpsRoots |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) }
)
$validWpsRoots = @($wpsRoots | Where-Object {
    Test-Path -LiteralPath $_ -PathType Container
})
$wpsRootHint = (
    'Create %USERPROFILE%\.codex\config\' +
    'aem-watch-resource-pipeline.local.json and configure tools.wpsRoots.'
)

if ($Capability -eq 'Translation') {
    Add-EnvironmentCheck -Condition ($validWpsRoots.Count -gt 0) `
        -Message "at least one WPS root exists: $($validWpsRoots -join ', ')" `
        -Hint $wpsRootHint
}
else {
    Add-EnvironmentWarning -Condition ($validWpsRoots.Count -gt 0) `
        -Message "WPS root available for optional translation work: $(
            $validWpsRoots -join ', '
        )" -Hint "WPS is required only when text translations change. $wpsRootHint"
}

$wpsSpreadsheet = $null
if ($validWpsRoots.Count -gt 0) {
    $wpsSpreadsheet = Find-PipelineWpsSpreadsheet -Roots $validWpsRoots
}
$spreadsheetMessage = "WPS spreadsheet executable exists: $(
    if ($null -ne $wpsSpreadsheet) { $wpsSpreadsheet.FullName } else { '' }
)"
if ($Capability -eq 'Translation') {
    Add-EnvironmentCheck -Condition ($null -ne $wpsSpreadsheet) `
        -Message $spreadsheetMessage `
        -Hint 'Check the configured WPS roots and installed WPS version.'
}
else {
    Add-EnvironmentWarning -Condition ($null -ne $wpsSpreadsheet) `
        -Message $spreadsheetMessage `
        -Hint 'Pure image/UI resource work can continue without WPS.'
}

$wpsProgId = [string]$config.tools.wpsProgId
$ketType = [type]::GetTypeFromProgID($wpsProgId)
Add-EnvironmentWarning -Condition ($null -ne $ketType) `
    -Message "$wpsProgId COM registration" `
    -Hint 'For translation work, rerun with -RegisterWps after locating WPS.'

Write-Output "CAPABILITY=$Capability"
Write-Output "APPLICATION=$($config.project.application)"
Write-Output "BOARD=$($config.project.board)"
Write-Output "RESOLUTION=$($config.project.resolution)"
Write-Output "PASS_COUNT=$script:PassCount"
Write-Output "WARNING_COUNT=$script:WarningCount"
Write-Output "FAILURE_COUNT=$script:FailureCount"

if ($script:FailureCount -gt 0) {
    Write-Output 'RESULT=FAILED'
    exit 1
}

Write-Output 'RESULT=SUCCESS'
