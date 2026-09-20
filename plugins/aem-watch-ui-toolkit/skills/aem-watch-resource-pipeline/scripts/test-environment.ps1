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

if ($Capability -eq 'Translation') {
    $backend = Resolve-PipelineTranslationBackend -Config $config `
        -ProjectRoot $project
    Write-Output "TRANSLATION_BACKEND_REQUESTED=$($backend.Requested)"
    Write-Output "TRANSLATION_BACKEND=$($backend.Selected)"

    if ($backend.Selected -eq 'poi') {
        Add-EnvironmentCheck -Condition $backend.PoiAllowed `
            -Message 'POI backend is allowed for the configured workbook container' `
            -Hint (
                'Projects that require protectedWrapperTokens must use the WPS backend.'
            )
        Add-EnvironmentCheck -Condition $backend.Java.Available `
            -Message "Java runtime exists: $($backend.Java.Path)" `
            -Hint (
                'Configure tools.javaExecutable in %USERPROFILE%\.codex\config\' +
                'aem-watch-resource-pipeline.local.json.'
            )
        Add-EnvironmentCheck -Condition $backend.Poi.Available `
            -Message "bundled POI writer exists: $($backend.Poi.Helper)" `
            -Hint (
                'Reinstall the complete aem-watch-ui-toolkit Plugin package. Missing: ' +
                ($backend.Poi.Missing -join ', ')
            )

        $poiRuntimeOk = $false
        $poiVersion = @()
        if ($backend.Java.Available -and $backend.Poi.Available) {
            $global:LASTEXITCODE = 0
            $poiVersion = @(& $backend.Java.Path `
                '-Dlog4j2.loggerContextFactory=org.apache.logging.log4j.simple.SimpleLoggerContextFactory' `
                '-cp' $backend.Poi.ClassPath 'AemWatchXlsTool' '--version' 2>&1)
            $poiRuntimeOk = ($LASTEXITCODE -eq 0)
        }
        Add-EnvironmentCheck -Condition $poiRuntimeOk `
            -Message "POI writer runtime starts: $($poiVersion -join '; ')" `
            -Hint 'Check the configured Java runtime and reinstall the Plugin package.'

        $activeLanguages = @()
        $inspectionError = ''
        if ($poiRuntimeOk -and
            (Test-Path -LiteralPath $translationTable -PathType Leaf)) {
            try {
                $activeLanguages = @(
                    Get-PipelineWorkbookActiveLanguages -Config $config `
                        -ProjectRoot $project -WorkbookPath $translationTable `
                        -Backend $backend
                )
            }
            catch {
                $inspectionError = $_.Exception.Message
            }
        }
        Add-EnvironmentCheck -Condition ($activeLanguages.Count -gt 0) `
            -Message "workbook active languages detected: $($activeLanguages -join ',')" `
            -Hint (
                'Check translation.languageColumns and translation.languageCodeRow. ' +
                $inspectionError
            )
        if ($activeLanguages.Count -gt 0) {
            Write-Output "ACTIVE_LANGUAGES=$($activeLanguages -join ',')"
            Write-Output 'ACTIVE_LANGUAGES_SOURCE=workbook'
        }
    }
    else {
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
            'Configure tools.wpsRoots in %USERPROFILE%\.codex\config\' +
            'aem-watch-resource-pipeline.local.json.'
        )
        Add-EnvironmentCheck -Condition ($validWpsRoots.Count -gt 0) `
            -Message "at least one WPS root exists: $($validWpsRoots -join ', ')" `
            -Hint $wpsRootHint

        $wpsSpreadsheet = $null
        if ($validWpsRoots.Count -gt 0) {
            $wpsSpreadsheet = Find-PipelineWpsSpreadsheet -Roots $validWpsRoots
        }
        Add-EnvironmentCheck -Condition ($null -ne $wpsSpreadsheet) `
            -Message "WPS spreadsheet executable exists: $(
                if ($null -ne $wpsSpreadsheet) {
                    $wpsSpreadsheet.FullName
                }
                else { '' }
            )" -Hint 'Check the configured WPS roots and installed WPS version.'

        $wpsProgId = [string]$config.tools.wpsProgId
        $ketType = [type]::GetTypeFromProgID($wpsProgId)
        Add-EnvironmentWarning -Condition ($null -ne $ketType) `
            -Message "$wpsProgId COM registration" `
            -Hint 'Rerun TranslationPrepare/Apply with -RegisterWps if needed.'
    }
}

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
