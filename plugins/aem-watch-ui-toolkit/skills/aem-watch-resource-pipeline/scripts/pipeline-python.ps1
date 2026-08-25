Set-StrictMode -Version Latest

function Resolve-PipelinePython {
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedProjectRoot
    )

    $candidates = @()
    $configuredProperty = $Config.tools.PSObject.Properties[
        'pythonExecutable'
    ]
    if ($null -ne $configuredProperty -and
        -not [string]::IsNullOrWhiteSpace(
            [string]$configuredProperty.Value
        )) {
        $configured = Resolve-PipelineToolPath `
            -ProjectRoot $ResolvedProjectRoot `
            -Path ([string]$configuredProperty.Value)
        $candidates += [pscustomobject]@{
            Path = $configured
            PrefixArguments = @()
            Source = 'configuration'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $bundled = Join-Path $env:USERPROFILE (
            '.cache\codex-runtimes\codex-primary-runtime\' +
            'dependencies\python\python.exe'
        )
        $candidates += [pscustomobject]@{
            Path = $bundled
            PrefixArguments = @()
            Source = 'Codex bundled runtime'
        }
    }

    $pythonCommand = Get-Command 'python.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pythonCommand) {
        $candidates += [pscustomobject]@{
            Path = $pythonCommand.Source
            PrefixArguments = @()
            Source = 'PATH python.exe'
        }
    }

    $pyCommand = Get-Command 'py.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pyCommand) {
        $candidates += [pscustomobject]@{
            Path = $pyCommand.Source
            PrefixArguments = @('-3')
            Source = 'Python launcher'
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) {
            return $candidate
        }
    }

    throw (
        'Python 3 was not found. Configure tools.pythonExecutable in ' +
        '%USERPROFILE%\.codex\config\aem-watch-resource-pipeline.local.json.'
    )
}
