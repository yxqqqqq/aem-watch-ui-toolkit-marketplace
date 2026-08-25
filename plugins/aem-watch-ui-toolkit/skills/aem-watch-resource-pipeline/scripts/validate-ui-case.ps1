[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$ConfigPath,
    [string]$LocalConfigPath,

    [ValidateSet('Pre', 'Post')]
    [string]$Phase = 'Pre',

    [switch]$RepairManualDeclarations
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')

$script:PassCount = 0
$script:FailureCount = 0

function Add-Check {
    param([bool]$Condition, [string]$Message)

    if ($Condition) {
        $script:PassCount++
        Write-Output "PASS $Message"
    }
    else {
        $script:FailureCount++
        Write-Output "FAIL $Message"
    }
}

function Get-RegexCount {
    param([string]$Text, [string]$Pattern)
    return [regex]::Matches($Text, $Pattern).Count
}

$resolved = Resolve-AemWatchPipelineConfig -ProjectRoot $ProjectRoot `
    -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
$config = $resolved.Config
$project = $resolved.ProjectRoot
Write-PipelineConfigSummary -ResolvedConfig $resolved

$manifestFile = Resolve-PipelineInputPath -BasePath (Get-Location).Path `
    -Path $ManifestPath
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "Manifest not found: $manifestFile"
}
$manifest = Get-Content -LiteralPath $manifestFile -Encoding UTF8 -Raw |
    ConvertFrom-Json

$uiRelative = [string]$config.paths.uiProject
$includeRelative = [string]$config.paths.includeHeader
$stringMapRelative = [string]$config.paths.stringMap
$translationRelative = [string]$config.paths.translationTable
$boardResRelative = [string]$config.paths.boardResourceRoot

$uiPath = Resolve-PipelineProjectPath -ProjectRoot $project -Path $uiRelative
$includePath = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path $includeRelative
$stringMapPath = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path $stringMapRelative
$translationPath = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path $translationRelative
$boardResPath = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path $boardResRelative

Add-Check (Test-Path -LiteralPath $uiPath -PathType Leaf) "UI project exists"
Add-Check (Test-Path -LiteralPath $translationPath -PathType Leaf) `
    "translation table exists"

if (-not (Test-Path -LiteralPath $uiPath -PathType Leaf)) {
    throw "Cannot continue without $uiPath"
}

$uiText = Get-Content -LiteralPath $uiPath -Encoding UTF8 -Raw
$uiDirectory = Split-Path -Parent $uiPath

$pictures = @()
if ($null -ne $manifest.PSObject.Properties['pictures']) {
    $pictures = @($manifest.pictures)
}
$strings = @()
if ($null -ne $manifest.PSObject.Properties['strings']) {
    $strings = @($manifest.strings)
}
$targetFiles = @()
if ($null -ne $manifest.PSObject.Properties['target_files']) {
    $targetFiles = @($manifest.target_files | ForEach-Object { [string]$_ })
}
$activeLanguages = @()
if ($null -ne $manifest.PSObject.Properties['active_languages']) {
    $activeLanguages = @(
        $manifest.active_languages | ForEach-Object { [string]$_ }
    )
}

foreach ($picture in $pictures) {
    if ($null -eq $picture) { continue }

    $resourceName = [regex]::Escape([string]$picture.resource_name)
    $uiPicturePath = [string]$picture.ui_path
    $escapedUiPicturePath = [regex]::Escape($uiPicturePath)
    $assetRelative = $uiPicturePath -replace '^[.][\\/]', ''
    $assetCandidate = [System.IO.Path]::GetFullPath(
        (Join-Path $uiDirectory $assetRelative)
    )
    $assetPath = Resolve-PipelineProjectPath -ProjectRoot $project `
        -Path $assetCandidate

    Add-Check (Test-Path -LiteralPath $assetPath -PathType Leaf) `
        "image exists: $uiPicturePath"
    if (Test-Path -LiteralPath $assetPath -PathType Leaf) {
        Add-Check ((Get-Item -LiteralPath $assetPath).Length -gt 0) `
            "image is non-empty: $uiPicturePath"
    }

    $nameCount = Get-RegexCount $uiText (
        '<property\s+name="name"\s+value="' + $resourceName + '"\s*/>'
    )
    Add-Check ($nameCount -eq 1) `
        "one picture_resource name: $($picture.resource_name)"

    $layerCount = Get-RegexCount $uiText (
        '<property\s+name="0"\s+value="' +
        $escapedUiPicturePath +
        '"\s*/>'
    )
    Add-Check ($layerCount -eq 1) `
        "one picture layer path: $uiPicturePath"

    $globalCount = Get-RegexCount $uiText (
        '<picture\s+value="' + $escapedUiPicturePath + '"\s*/>'
    )
    Add-Check ($globalCount -eq 1) `
        "one global picture path: $uiPicturePath"
}

foreach ($string in $strings) {
    if ($null -eq $string) { continue }

    $resourceName = [regex]::Escape([string]$string.resource_name)
    $uiKey = [regex]::Escape([string]$string.ui_key)

    $nameCount = Get-RegexCount $uiText (
        '<property\s+name="name"\s+value="' + $resourceName + '"\s*/>'
    )
    Add-Check ($nameCount -eq 1) `
        "one string_resource name: $($string.resource_name)"

    $stridCount = Get-RegexCount $uiText (
        '<property\s+name="strid"\s+value="' + $uiKey + '"\s*/>'
    )
    Add-Check ($stridCount -eq 1) `
        "one string_resource strid: $($string.ui_key)"

    $globalCount = Get-RegexCount $uiText (
        '<string\s+value="' + $uiKey + '"\s*/>'
    )
    Add-Check ($globalCount -eq 1) `
        "one global string index: $($string.ui_key)"
}

foreach ($target in $targetFiles) {
    if ([string]::IsNullOrWhiteSpace($target)) { continue }
    $targetPath = Resolve-PipelineProjectPath -ProjectRoot $project -Path $target
    Add-Check (Test-Path -LiteralPath $targetPath -PathType Leaf) `
        "target file exists: $target"
}

if ($Phase -eq 'Post') {
    $generatedFiles = @(
        $config.generation.generatedFiles |
            ForEach-Object { [string]$_ }
    )

    foreach ($relative in $generatedFiles) {
        $generatedPath = Resolve-PipelineProjectPath -ProjectRoot $project `
            -Path $relative
        $exists = Test-Path -LiteralPath $generatedPath -PathType Leaf
        Add-Check $exists "generated file exists: $relative"
        if ($exists) {
            Add-Check ((Get-Item -LiteralPath $generatedPath).Length -gt 0) `
                "generated file is non-empty: $relative"
        }
    }

    if (Test-Path -LiteralPath $includePath -PathType Leaf) {
        $includeText = Get-Content -LiteralPath $includePath -Encoding UTF8 -Raw
        $manualDeclarations = @(
            $config.generation.manualDeclarations |
                ForEach-Object { [string]$_ }
        )

        $missingDeclarations = @(
            $manualDeclarations | Where-Object {
                -not $includeText.Contains($_)
            }
        )
        if ($RepairManualDeclarations -and $missingDeclarations.Count -gt 0) {
            $newline = "`n"
            if ($includeText.Contains("`r`n")) {
                $newline = "`r`n"
            }
            $insert = $newline + ($missingDeclarations -join $newline) +
                $newline + $newline
            $insertPattern = [string](
                $config.generation.manualDeclarationInsertPattern
            )
            $updatedInclude = [regex]::Replace(
                $includeText,
                $insertPattern,
                $insert + '#endif //__RES_INCLUDE_H__',
                1
            )
            if ($updatedInclude -eq $includeText) {
                throw 'Could not locate the configured include guard closing line.'
            }
            [System.IO.File]::WriteAllText(
                $includePath,
                $updatedInclude,
                (New-Object System.Text.UTF8Encoding($false))
            )
            $includeText = $updatedInclude
            Write-Output (
                "REPAIRED manual declarations: {0}" -f
                ($missingDeclarations -join ', ')
            )
        }

        foreach ($picture in $pictures) {
            if ($null -eq $picture) { continue }
            Add-Check ($includeText.Contains([string]$picture.symbol)) `
                "generated image symbol: $($picture.symbol)"
        }
        foreach ($string in $strings) {
            if ($null -eq $string) { continue }
            Add-Check ($includeText.Contains([string]$string.symbol)) `
                "generated string symbol: $($string.symbol)"
        }

        foreach ($manualDeclaration in $manualDeclarations) {
            Add-Check ($includeText.Contains($manualDeclaration)) `
                "manual declaration preserved: $manualDeclaration"
        }
    }

    if (Test-Path -LiteralPath $stringMapPath -PathType Leaf) {
        $stringMapText = Get-Content -LiteralPath $stringMapPath `
            -Encoding UTF8 -Raw
        foreach ($string in $strings) {
            if ($null -eq $string) { continue }
            $escapedKey = [regex]::Escape([string]$string.ui_key)
            $mappingCount = Get-RegexCount $stringMapText (
                '\.key\s*=\s*"' + $escapedKey + '"'
            )
            Add-Check ($mappingCount -eq 1) `
                "one generated key mapping: $($string.ui_key)"
        }
    }

    $languageResourceStem = [string](
        $config.generation.languageResourceStem
    )
    foreach ($languageCode in $activeLanguages) {
        $languagePath = Join-Path $boardResPath (
            "$languageResourceStem.$languageCode"
        )
        $exists = Test-Path -LiteralPath $languagePath -PathType Leaf
        Add-Check $exists "language resource exists: $languageCode"
        if (-not $exists) { continue }

        $languageBytes = [System.IO.File]::ReadAllBytes($languagePath)
        $languageText = [System.Text.Encoding]::UTF8.GetString($languageBytes)
        foreach ($string in $strings) {
            if ($null -eq $string) { continue }
            $translationProperty = @(
                $string.translations.PSObject.Properties |
                    Where-Object { $_.Name -eq $languageCode }
            )
            if ($translationProperty.Count -eq 1) {
                $expectedText = [string]$translationProperty[0].Value
                Add-Check ($languageText.Contains($expectedText)) `
                    "generated text matches: $($string.table_key)/$languageCode"
            }
        }
    }

    $diffPaths = @(
        $uiRelative,
        $translationRelative,
        $includeRelative,
        $stringMapRelative
    )
    $diffPaths += $targetFiles

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $diffOutput = & git -C $project diff --check -- @diffPaths 2>&1
    $diffExit = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    Add-Check ($diffExit -eq 0) 'git diff --check passes for scoped files'
    if ($diffExit -ne 0) {
        $diffOutput | ForEach-Object { Write-Output "DIFF_CHECK $_" }
    }
}

Write-Output "PHASE=$Phase"
Write-Output "PASS_COUNT=$script:PassCount"
Write-Output "FAILURE_COUNT=$script:FailureCount"

if ($script:FailureCount -gt 0) {
    Write-Output 'RESULT=FAILED'
    exit 1
}

Write-Output 'RESULT=SUCCESS'
