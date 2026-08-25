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
