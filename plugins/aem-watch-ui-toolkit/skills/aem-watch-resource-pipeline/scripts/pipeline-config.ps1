Set-StrictMode -Version Latest

function Read-PipelineJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON configuration '$Path': $($_.Exception.Message)"
    }
}

function Merge-PipelineObject {
    param(
        [Parameter(Mandatory = $true)]
        $Target,

        [Parameter(Mandatory = $true)]
        $Source
    )

    foreach ($property in $Source.PSObject.Properties) {
        $name = [string]$property.Name
        $existing = $Target.PSObject.Properties[$name]
        $sourceValue = $property.Value

        if ($null -ne $existing -and
            $existing.Value -is [System.Management.Automation.PSCustomObject] -and
            $sourceValue -is [System.Management.Automation.PSCustomObject]) {
            Merge-PipelineObject -Target $existing.Value -Source $sourceValue
            continue
        }

        if ($null -ne $existing) {
            $existing.Value = $sourceValue
        }
        else {
            $Target | Add-Member -NotePropertyName $name `
                -NotePropertyValue $sourceValue
        }
    }
}

function Expand-PipelineTokens {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $application = [string]$Config.project.application
    $board = [string]$Config.project.board
    $resolution = [string]$Config.project.resolution

    foreach ($value in @($application, $board, $resolution)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'Project application, board, and resolution must be configured.'
        }
    }

    $json = $Config | ConvertTo-Json -Depth 100
    $json = $json.Replace('{application}', $application)
    $json = $json.Replace('{board}', $board)
    $json = $json.Replace('{resolution}', $resolution)
    return $json | ConvertFrom-Json
}

function Test-PipelineRootMarkers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Markers
    )

    foreach ($marker in $Markers) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $marker))) {
            return $false
        }
    }
    return $true
}

function Find-PipelineProjectRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StartPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Markers
    )

    $candidate = [System.IO.Path]::GetFullPath($StartPath)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $candidate = Split-Path -Parent $candidate
    }

    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-PipelineRootMarkers -Root $candidate -Markers $Markers) {
            return $candidate
        }

        $parent = [System.IO.Directory]::GetParent($candidate)
        if ($null -eq $parent -or $parent.FullName -eq $candidate) {
            break
        }
        $candidate = $parent.FullName
    }

    throw "Could not discover project root from '$StartPath'. Required markers: " +
        ($Markers -join ', ')
}

function Resolve-PipelineProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    }
    else {
        $resolvedPath = [System.IO.Path]::GetFullPath(
            (Join-Path $resolvedRoot $Path)
        )
    }

    $rootWithSeparator = $resolvedRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if ($resolvedPath -ne $resolvedRoot -and
        -not $resolvedPath.StartsWith(
            $rootWithSeparator,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Path escapes project root: $resolvedPath"
    }
    return $resolvedPath
}

function Resolve-PipelineInputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-PipelineToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return Resolve-PipelineProjectPath -ProjectRoot $ProjectRoot -Path $Path
}

function Get-PipelineLanguageColumns {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $columns = [ordered]@{}
    foreach ($property in $Config.translation.languageColumns.PSObject.Properties) {
        $column = [int]$property.Value
        if ($column -lt 1) {
            throw "Invalid column for language '$($property.Name)': $column"
        }
        $columns[[string]$property.Name] = $column
    }
    if ($columns.Count -eq 0) {
        throw 'No translation language columns are configured.'
    }
    return $columns
}

function Find-PipelineWpsSpreadsheet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Roots
    )

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root) -or
            -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $root -Filter 'et.exe' `
            -File -Recurse |
            Where-Object { $_.DirectoryName -match '[\\/]office6$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }
    return $null
}

function Resolve-PipelineJavaRuntime {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $configured = [string]$Config.tools.javaExecutable
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $path = Resolve-PipelineToolPath -ProjectRoot $ProjectRoot `
            -Path $configured
        return [pscustomobject]@{
            Path = $path
            Source = 'configured tools.javaExecutable'
            Available = (Test-Path -LiteralPath $path -PathType Leaf)
        }
    }

    $command = Get-Command 'java.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        return [pscustomobject]@{
            Path = $command.Source
            Source = 'PATH'
            Available = $true
        }
    }

    return [pscustomobject]@{
        Path = ''
        Source = 'not found'
        Available = $false
    }
}

function Get-PipelinePoiTool {
    $root = Join-Path $PSScriptRoot 'poi'
    $helper = Join-Path $root 'aem-watch-xls-tool.jar'
    $expectedLibraries = @(
        'commons-codec-1.20.0.jar',
        'commons-collections4-4.5.0.jar',
        'commons-io-2.21.0.jar',
        'commons-math3-3.6.1.jar',
        'log4j-api-2.24.3.jar',
        'poi-5.5.1.jar',
        'SparseBitSet-1.3.jar'
    )
    $libraries = @($expectedLibraries | ForEach-Object {
        Join-Path (Join-Path $root 'lib') $_
    })
    $missing = @($helper) + $libraries |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    $classPath = (@($helper) + $libraries) -join (
        [System.IO.Path]::PathSeparator
    )

    return [pscustomobject]@{
        Root = $root
        Helper = $helper
        Libraries = $libraries
        ClassPath = $classPath
        Missing = @($missing)
        Available = (@($missing).Count -eq 0)
    }
}

function Resolve-PipelineTranslationBackend {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $requested = [string]$Config.translation.backend
    if ([string]::IsNullOrWhiteSpace($requested)) {
        $requested = 'auto'
    }
    if ($requested -notin @('auto', 'poi', 'wps')) {
        throw "Unsupported translation backend '$requested'."
    }

    $wrapperTokens = @(
        $Config.translation.protectedWrapperTokens |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $java = Resolve-PipelineJavaRuntime -Config $Config `
        -ProjectRoot $ProjectRoot
    $poi = Get-PipelinePoiTool
    $poiAllowed = ($wrapperTokens.Count -eq 0)
    $poiReady = ($poiAllowed -and $java.Available -and $poi.Available)

    $selected = $requested
    if ($requested -eq 'auto') {
        if ($poiReady) {
            $selected = 'poi'
        }
        else {
            $selected = 'wps'
        }
    }

    return [pscustomobject]@{
        Requested = $requested
        Selected = $selected
        PoiAllowed = $poiAllowed
        PoiReady = $poiReady
        WrapperTokens = $wrapperTokens
        Java = $java
        Poi = $poi
    }
}

function ConvertTo-PipelineJobBase64 {
    param([AllowEmptyString()][string]$Text)

    return [Convert]::ToBase64String(
        [System.Text.Encoding]::UTF8.GetBytes($Text)
    )
}

function Get-PipelineWorkbookActiveLanguages {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        [string]$WorkbookPath,

        $Backend
    )

    if ($null -eq $Backend) {
        $Backend = Resolve-PipelineTranslationBackend -Config $Config `
            -ProjectRoot $ProjectRoot
    }
    if ($Backend.Selected -ne 'poi' -or
        -not $Backend.Java.Available -or
        -not $Backend.Poi.Available) {
        throw 'POI workbook inspection is unavailable.'
    }

    $languageColumns = Get-PipelineLanguageColumns -Config $Config
    $jobRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
        'codex-aem-watch-resource\jobs'
    )
    [System.IO.Directory]::CreateDirectory($jobRoot) | Out-Null
    $jobPath = Join-Path $jobRoot (
        'translation-inspect-' + [guid]::NewGuid().ToString('N') + '.txt'
    )
    $jobLines = New-Object 'System.Collections.Generic.List[string]'
    [void]$jobLines.Add('version=1')
    [void]$jobLines.Add('mode=inspect')
    [void]$jobLines.Add(
        'input=' + (ConvertTo-PipelineJobBase64 $WorkbookPath)
    )
    [void]$jobLines.Add('output=')
    [void]$jobLines.Add("keyColumn=$([int]$Config.translation.keyColumn)")
    [void]$jobLines.Add(
        "languageCodeRow=$([int]$Config.translation.languageCodeRow)"
    )
    [void]$jobLines.Add("dataStartRow=$([int]$Config.translation.dataStartRow)")
    foreach ($pair in $languageColumns.GetEnumerator()) {
        [void]$jobLines.Add(
            'language=' +
            (ConvertTo-PipelineJobBase64 ([string]$pair.Key)) +
            '|' + [string]$pair.Value
        )
    }
    [System.IO.File]::WriteAllLines(
        $jobPath,
        $jobLines,
        (New-Object System.Text.UTF8Encoding($false))
    )

    try {
        $javaArguments = @(
            (
                '-Dlog4j2.loggerContextFactory=' +
                'org.apache.logging.log4j.simple.SimpleLoggerContextFactory'
            ),
            '-cp',
            $Backend.Poi.ClassPath,
            'AemWatchXlsTool',
            '--job',
            $jobPath
        )
        $global:LASTEXITCODE = 0
        $poiOutput = @(& $Backend.Java.Path @javaArguments 2>&1 |
            ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) {
            throw "POI workbook inspection failed: $($poiOutput -join '; ')"
        }
        if (-not ($poiOutput -contains 'RESULT=SUCCESS')) {
            throw 'POI workbook inspection did not report success.'
        }
        $languageLines = @($poiOutput | Where-Object {
            $_.StartsWith('ACTIVE_LANGUAGES=')
        })
        if ($languageLines.Count -ne 1) {
            throw 'POI workbook inspection returned an invalid language result.'
        }
        $serialized = $languageLines[0].Substring('ACTIVE_LANGUAGES='.Length)
        $languages = @(
            $serialized.Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($languages.Count -eq 0) {
            throw 'The workbook language code row has no active languages.'
        }
        return $languages
    }
    finally {
        Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-AemWatchPipelineConfig {
    param(
        [string]$ProjectRoot,
        [string]$ConfigPath,
        [string]$LocalConfigPath
    )

    $skillRoot = Split-Path -Parent $PSScriptRoot
    $defaultPath = Join-Path $skillRoot 'config\defaults.json'
    $config = Read-PipelineJson -Path $defaultPath
    $loadedFiles = @([System.IO.Path]::GetFullPath($defaultPath))

    $effectiveLocalPath = $LocalConfigPath
    if ([string]::IsNullOrWhiteSpace($effectiveLocalPath) -and
        -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $effectiveLocalPath = Join-Path $env:USERPROFILE `
            '.codex\config\aem-watch-resource-pipeline.local.json'
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveLocalPath)) {
        $resolvedLocalPath = [System.IO.Path]::GetFullPath($effectiveLocalPath)
        if (Test-Path -LiteralPath $resolvedLocalPath -PathType Leaf) {
            Merge-PipelineObject -Target $config `
                -Source (Read-PipelineJson -Path $resolvedLocalPath)
            $loadedFiles += $resolvedLocalPath
        }
        elseif (-not [string]::IsNullOrWhiteSpace($LocalConfigPath)) {
            throw "Local configuration file not found: $resolvedLocalPath"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $resolvedConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
        Merge-PipelineObject -Target $config `
            -Source (Read-PipelineJson -Path $resolvedConfigPath)
        $loadedFiles += $resolvedConfigPath
    }

    if ([int]$config.schemaVersion -ne 1) {
        throw "Unsupported pipeline configuration schema: " +
            $config.schemaVersion
    }

    $config = Expand-PipelineTokens -Config $config
    $markers = @($config.project.rootMarkers | ForEach-Object { [string]$_ })
    if ($markers.Count -eq 0) {
        throw 'At least one project root marker must be configured.'
    }

    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $resolvedProjectRoot = Find-PipelineProjectRoot `
            -StartPath (Get-Location).Path -Markers $markers
    }
    else {
        $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
        if (-not (Test-PipelineRootMarkers -Root $resolvedProjectRoot `
            -Markers $markers)) {
            throw "Configured project root '$resolvedProjectRoot' does not " +
                "contain all required markers: $($markers -join ', ')"
        }
    }

    return [pscustomobject]@{
        Config = $config
        ProjectRoot = $resolvedProjectRoot
        LoadedConfigFiles = $loadedFiles
        LocalConfigPath = $effectiveLocalPath
    }
}

function Write-PipelineConfigSummary {
    param(
        [Parameter(Mandatory = $true)]
        $ResolvedConfig
    )

    Write-Output "PROJECT_ROOT=$($ResolvedConfig.ProjectRoot)"
    Write-Output "CONFIG_FILES=$(
        @($ResolvedConfig.LoadedConfigFiles) -join ';'
    )"
}
