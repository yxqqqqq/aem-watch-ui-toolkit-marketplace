[CmdletBinding()]
param(
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$ConfigPath,
    [string]$LocalConfigPath,

    [switch]$Apply,
    [switch]$RegisterWps,

    [string]$WorkbookRelativePath,
    [string[]]$WpsRoot,
    [string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'pipeline-config.ps1')

function Get-TranslationProperty {
    param($Translations, [string]$Code)

    return @(
        $Translations.PSObject.Properties |
            Where-Object { $_.Name -eq $Code }
    )
}

function Get-PrintfTokens {
    param([string]$Text)

    return @(
        [regex]::Matches(
            $Text,
            '%(?:%|[-+ #0]*\d*(?:\.\d+)?[diuoxXfFeEgGaAcspn])'
        ) | ForEach-Object { $_.Value }
    )
}

function Assert-TranslationSafety {
    param(
        $Entry,
        [string[]]$Codes,
        [string]$ForcedBreakToken
    )

    $baseline = $null
    foreach ($code in $Codes) {
        $property = @(Get-TranslationProperty $Entry.translations $code)
        if ($property.Count -ne 1) {
            throw "Missing translation '$code' for key '$($Entry.table_key)'"
        }

        $text = [string]$property[0].Value
        $allowForcedBreak = $false
        if ($null -ne $Entry.PSObject.Properties['allow_forced_break']) {
            $allowForcedBreak = [bool]$Entry.allow_forced_break
        }

        if (-not $allowForcedBreak) {
            if ((-not [string]::IsNullOrEmpty($ForcedBreakToken) -and
                    $text.Contains($ForcedBreakToken)) -or
                $text.Contains("`r") -or
                $text.Contains("`n")) {
                throw "Forced break is not allowed for '$($Entry.table_key)'/$code"
            }
        }

        $tokens = (Get-PrintfTokens $text) -join ([char]31)
        if ($null -eq $baseline) {
            $baseline = $tokens
        }
        elseif ($tokens -ne $baseline) {
            throw "Printf placeholders differ for '$($Entry.table_key)'/$code"
        }
    }
}

$resolved = Resolve-AemWatchPipelineConfig -ProjectRoot $ProjectRoot `
    -ConfigPath $ConfigPath -LocalConfigPath $LocalConfigPath
$config = $resolved.Config
$project = $resolved.ProjectRoot
Write-PipelineConfigSummary -ResolvedConfig $resolved

$manifestFile = Resolve-PipelineInputPath -BasePath (Get-Location).Path `
    -Path $ManifestPath
if ([string]::IsNullOrWhiteSpace($WorkbookRelativePath)) {
    $WorkbookRelativePath = [string]$config.paths.translationTable
}
$workbookPath = Resolve-PipelineProjectPath -ProjectRoot $project `
    -Path $WorkbookRelativePath

if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "Manifest not found: $manifestFile"
}
if (-not (Test-Path -LiteralPath $workbookPath -PathType Leaf)) {
    throw "Workbook not found: $workbookPath"
}

$manifest = Get-Content -LiteralPath $manifestFile -Encoding UTF8 -Raw |
    ConvertFrom-Json
$entries = @()
if ($null -ne $manifest.PSObject.Properties['strings']) {
    $entries = @($manifest.strings)
}
if ($entries.Count -eq 0) {
    throw 'Manifest has no string entries.'
}

$languageColumns = Get-PipelineLanguageColumns -Config $config
$keyColumn = [int]$config.translation.keyColumn
$languageCodeRow = [int]$config.translation.languageCodeRow
$dataStartRow = [int]$config.translation.dataStartRow
$forcedBreakToken = [string]$config.translation.forcedBreakToken
$wrapperTokens = @(
    $config.translation.protectedWrapperTokens |
        ForEach-Object { [string]$_ }
)
$wpsProgId = [string]$config.tools.wpsProgId

$wpsRoots = @()
if ($PSBoundParameters.ContainsKey('WpsRoot')) {
    $wpsRoots = @($WpsRoot | ForEach-Object {
        [System.IO.Path]::GetFullPath([string]$_)
    })
}
else {
    $wpsRoots = @($config.tools.wpsRoots | ForEach-Object {
        [System.IO.Path]::GetFullPath([string]$_)
    })
}

$ketType = [type]::GetTypeFromProgID($wpsProgId)
if ($null -eq $ketType -and $RegisterWps) {
    $wps = Find-PipelineWpsSpreadsheet -Roots $wpsRoots
    if ($null -eq $wps) {
        throw "WPS et.exe not found under configured roots: " +
            ($wpsRoots -join ', ')
    }

    $registerProcess = Start-Process -FilePath $wps.FullName `
        -ArgumentList '/register' -WindowStyle Hidden -PassThru -Wait
    if ($registerProcess.ExitCode -ne 0) {
        throw "WPS registration failed with exit code $($registerProcess.ExitCode)"
    }
    $ketType = [type]::GetTypeFromProgID($wpsProgId)
}

if ($null -eq $ketType) {
    throw "$wpsProgId is not registered. Re-run with -RegisterWps."
}

if ($Apply) {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            'codex-aem-watch-resource\' + (Get-Date -Format 'yyyyMMdd_HHmmss')
        )
    }
    $resolvedBackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
    New-Item -ItemType Directory -Path $resolvedBackupRoot -Force | Out-Null
    $backupName = '{0}.before{1}' -f
        [System.IO.Path]::GetFileNameWithoutExtension($workbookPath),
        [System.IO.Path]::GetExtension($workbookPath)
    $backupPath = Join-Path $resolvedBackupRoot $backupName
    Copy-Item -LiteralPath $workbookPath -Destination $backupPath -Force

    $sourceHash = (Get-FileHash -LiteralPath $workbookPath -Algorithm SHA256).Hash
    $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    if ($sourceHash -ne $backupHash) {
        throw 'Workbook backup hash mismatch.'
    }

    Write-Output "BACKUP=$backupPath"
    Write-Output "BACKUP_SHA256=$backupHash"
}

$app = $null
$workbook = $null
$sheet = $null

try {
    $app = New-Object -ComObject $wpsProgId
    $initialWorkbookCount = [int]$app.Workbooks.Count
    $initialVisible = [bool]$app.Visible
    $oldAlerts = [bool]$app.DisplayAlerts
    $app.DisplayAlerts = $false

    $workbook = $app.Workbooks.Open($workbookPath, 0, (-not $Apply))
    if ($Apply -and [bool]$workbook.ReadOnly) {
        throw 'WPS opened the workbook as read-only.'
    }

    $sheet = $workbook.Worksheets.Item(1)
    $usedRows = [int]$sheet.UsedRange.Rows.Count

    $actualActive = @()
    foreach ($pair in $languageColumns.GetEnumerator()) {
        $rowCode = [string]$sheet.Cells.Item(
            $languageCodeRow,
            $pair.Value
        ).Value2
        if (-not [string]::IsNullOrWhiteSpace($rowCode)) {
            $actualActive += $rowCode
        }
    }

    $expectedActive = @()
    if ($null -ne $manifest.PSObject.Properties['active_languages']) {
        $expectedActive = @($manifest.active_languages | ForEach-Object {
            [string]$_
        })
    }
    if ($expectedActive.Count -gt 0) {
        if (($expectedActive -join ',') -ne ($actualActive -join ',')) {
            throw "Manifest active languages '$($expectedActive -join ',')' " +
                "do not match workbook '$($actualActive -join ',')'."
        }
    }
    else {
        $expectedActive = $actualActive
    }

    $changedCells = 0
    $rowByKey = @{}

    foreach ($entry in $entries) {
        Assert-TranslationSafety -Entry $entry -Codes $expectedActive `
            -ForcedBreakToken $forcedBreakToken

        $matches = @()
        for ($row = $dataStartRow; $row -le $usedRows; $row++) {
            if ([string]$sheet.Cells.Item($row, $keyColumn).Value2 -eq
                [string]$entry.table_key) {
                $matches += $row
            }
        }

        if ($matches.Count -ne 1) {
            throw "Expected one row for '$($entry.table_key)', found " +
                "$($matches.Count)."
        }

        $targetRow = $matches[0]
        $rowByKey[[string]$entry.table_key] = $targetRow

        foreach ($property in $entry.translations.PSObject.Properties) {
            $code = [string]$property.Name
            if (-not $languageColumns.Contains($code)) {
                throw "Unknown language code '$code'."
            }

            $column = [int]$languageColumns[$code]
            $current = [string]$sheet.Cells.Item($targetRow, $column).Value2
            $proposed = [string]$property.Value

            Write-Output (
                "TEXT key={0} lang={1} row={2} current={3} proposed={4}" -f
                $entry.table_key,
                $code,
                $targetRow,
                ($current -replace "`r", '<CR>' -replace "`n", '<LF>'),
                ($proposed -replace "`r", '<CR>' -replace "`n", '<LF>')
            )

            if ($Apply -and $current -ne $proposed) {
                $sheet.Cells.Item($targetRow, $column).Value2 = $proposed
                $changedCells++
            }
        }

        $missingOptional = @()
        foreach ($pair in $languageColumns.GetEnumerator()) {
            if ($expectedActive -contains $pair.Key) {
                continue
            }
            $value = [string]$sheet.Cells.Item(
                $targetRow,
                $pair.Value
            ).Value2
            if ([string]::IsNullOrWhiteSpace($value)) {
                $missingOptional += $pair.Key
            }
        }
        Write-Output (
            "MISSING_OPTIONAL key={0} languages={1}" -f
            $entry.table_key,
            ($missingOptional -join ',')
        )
    }

    if ($Apply) {
        $workbook.Save()
    }
    $workbook.Close($false)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook)
    $workbook = $null

    if ($Apply) {
        $workbook = $app.Workbooks.Open($workbookPath, 0, $true)
        $sheet = $workbook.Worksheets.Item(1)

        foreach ($entry in $entries) {
            $targetRow = [int]$rowByKey[[string]$entry.table_key]
            foreach ($property in $entry.translations.PSObject.Properties) {
                $column = [int]$languageColumns[[string]$property.Name]
                $saved = [string]$sheet.Cells.Item($targetRow, $column).Value2
                if ($saved -ne [string]$property.Value) {
                    throw "Saved value mismatch for '$($entry.table_key)'/" +
                        "$($property.Name)."
                }
            }
        }

        $workbook.Close($false)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook)
        $workbook = $null
    }

    $app.DisplayAlerts = $oldAlerts
    if ($initialWorkbookCount -eq 0 -and -not $initialVisible) {
        $app.Quit()
    }

    $prefixBytes = [System.IO.File]::ReadAllBytes($workbookPath)
    $prefixLength = [Math]::Min(128, $prefixBytes.Length)
    $prefix = [System.Text.Encoding]::ASCII.GetString(
        $prefixBytes,
        0,
        $prefixLength
    )
    foreach ($token in $wrapperTokens) {
        if (-not $prefix.Contains($token)) {
            throw "Saved workbook no longer contains wrapper token '$token'."
        }
    }

    Write-Output "ACTIVE_LANGUAGES=$($expectedActive -join ',')"
    Write-Output "CHANGED_CELLS=$changedCells"
    Write-Output "WORKBOOK_SHA256=$(
        (Get-FileHash -LiteralPath $workbookPath -Algorithm SHA256).Hash
    )"
    Write-Output 'RESULT=SUCCESS'
}
finally {
    if ($null -ne $sheet) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($sheet)
    }
    if ($null -ne $workbook) {
        try { $workbook.Close($false) } catch {}
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook)
    }
    if ($null -ne $app) {
        try {
            if ([int]$app.Workbooks.Count -eq 0) {
                $app.Quit()
            }
        }
        catch {}
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($app)
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
