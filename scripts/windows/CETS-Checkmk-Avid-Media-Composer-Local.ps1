<#
.SYNOPSIS
    CETS - Checkmk local checks for Avid Media Composer edit suites

.DESCRIPTION
    Emits Checkmk local-check output for lightweight Avid edit-suite monitoring.

    Install this file on each Windows client at:
      C:\ProgramData\checkmk\agent\local\CETS-Checkmk-Avid-Media-Composer-Local.ps1

    The Checkmk Windows agent runs scripts from that local directory when the
    monitoring server polls the agent. This script also keeps its own short
    cache so frequent polls do not repeatedly query services and event logs.

.NOTES
    Output format:
      <state> "<service name>" <metrics> <details>

    States:
      0 = OK
      1 = WARN
      2 = CRIT
      3 = UNKNOWN
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

$CacheSeconds = 300
$EventLookbackMinutes = 60
$MaxRecentEvents = 5

$CacheDirectory = 'C:\ProgramData\CETS\CheckmkLocalChecks'
$CacheFile = Join-Path $CacheDirectory 'avid_media_composer_local_check.out'

$RequiredServices = @(
    'AvidFosFS',
    'AvidNEXISClientLoggingService',
    'AvidSearchDb',
    'AudioEndpointBuilder',
    'Audiosrv',
    'dvhlp',
    'NVDisplay.ContainerLocalSystem',
    'PaceLicenseDServices',
    'SentinelKeysServer',
    'SentinelProtectionServer',
    'SentinelSecurityRuntime'
)

$OptionalServices = @(
    'Avid_Editor_Broker',
    'Avid_Editor_Db_Engine',
    'Avid_Editor_Transcode_Status',
    'Avid_NEXIS_Benchmark_Agent'
)

$AvidProcessNames = @(
    'AvidMediaComposer',
    'AvidMediaComposerFirst'
)

$MediaComposerInstallPaths = @(
    'C:\Program Files\Avid\Avid Media Composer\AvidMediaComposer.exe',
    'C:\Program Files\Avid\Avid Media Composer\AvidMediaComposerFirst.exe'
)

$AvidEventLogs = @(
    'Application',
    'System'
)

$AvidEventPatterns = @(
    'avid',
    'nexis',
    'sentinel',
    'pace'
)

$IgnoredEventPatterns = @(
    'intelmeprov'
)

# Adapter names differ between generations. This is intentionally broad and
# only reports a warning if an obvious edit/storage adapter is disconnected.
$ImportantAdapterPatterns = @(
    'marvell',
    'aqtion',
    'x520',
    'x550',
    '10gbe',
    '10gb',
    'nexis',
    'avid'
)

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

function Escape-CheckmkText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'No details'
    }

    return (($Text -replace '\r?\n', ' ') -replace '\s{2,}', ' ').Trim()
}

function New-CheckmkLine {
    param(
        [Parameter(Mandatory = $true)][int]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Details,
        [string]$Metrics = '-'
    )

    $SafeName = $Name.Replace('"', "'")
    $SafeDetails = Escape-CheckmkText -Text $Details
    return ('{0} "{1}" {2} {3}' -f $State, $SafeName, $Metrics, $SafeDetails)
}

function Test-TextContainsAny {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )

    $NormalisedText = $Text.ToLowerInvariant()
    foreach ($Pattern in $Patterns) {
        if ($NormalisedText.Contains($Pattern)) {
            return $true
        }
    }

    return $false
}

function Test-CacheFresh {
    if (-not (Test-Path -LiteralPath $CacheFile)) {
        return $false
    }

    $AgeSeconds = ((Get-Date) - (Get-Item -LiteralPath $CacheFile).LastWriteTime).TotalSeconds
    return ($AgeSeconds -lt $CacheSeconds)
}

function Get-ServiceMap {
    $ServiceNames = @($RequiredServices + $OptionalServices) | Sort-Object -Unique
    $Services = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE '%'" |
        Where-Object { $ServiceNames -contains $_.Name }

    $Map = @{}
    foreach ($Service in $Services) {
        $Map[$Service.Name] = $Service
    }
    return $Map
}

function Get-AvidServiceLine {
    $ServiceMap = Get-ServiceMap
    $Missing = @()
    $MissingOptional = @()
    $Stopped = @()
    $Manual = @()

    foreach ($Name in $RequiredServices) {
        if (-not $ServiceMap.ContainsKey($Name)) {
            $Missing += $Name
            continue
        }

        $Service = $ServiceMap[$Name]
        if ($Service.State -ne 'Running') {
            $Stopped += ('{0}={1}' -f $Name, $Service.State)
        }

        if ($Service.StartMode -ne 'Auto') {
            $Manual += ('{0}={1}' -f $Name, $Service.StartMode)
        }
    }

    foreach ($Name in $OptionalServices) {
        if (-not $ServiceMap.ContainsKey($Name)) {
            $MissingOptional += $Name
        }
    }

    $Metrics = 'required_services={0}|running_issues={1}|start_mode_issues={2}|missing_optional={3}' -f $RequiredServices.Count, $Stopped.Count, $Manual.Count, $MissingOptional.Count

    if ($Missing.Count -gt 0 -or $Stopped.Count -gt 0) {
        $Details = 'Required Avid/NEXIS/licensing services need attention. Missing: {0}. Not running: {1}. Non-auto start: {2}. Optional helper services not present: {3}.' -f `
            (($Missing -join ', ') -replace '^$', 'none'),
            (($Stopped -join ', ') -replace '^$', 'none'),
            (($Manual -join ', ') -replace '^$', 'none'),
            (($MissingOptional -join ', ') -replace '^$', 'none')
        return New-CheckmkLine -State 2 -Name 'CETS Avid Required Services' -Metrics $Metrics -Details $Details
    }

    if ($Manual.Count -gt 0) {
        $Details = 'All required Avid/NEXIS/licensing services are running; non-auto start mode: {0}. Optional helper services not present: {1}.' -f `
            ($Manual -join ', '),
            (($MissingOptional -join ', ') -replace '^$', 'none')
        return New-CheckmkLine -State 1 -Name 'CETS Avid Required Services' -Metrics $Metrics -Details $Details
    }

    $Details = 'All required Avid/NEXIS/licensing/audio/GPU services are running and set to automatic start. Optional helper services not present: {0}.' -f `
        (($MissingOptional -join ', ') -replace '^$', 'none')
    return New-CheckmkLine -State 0 -Name 'CETS Avid Required Services' -Metrics $Metrics -Details $Details
}

function Get-AvidApplicationLine {
    $InstalledPaths = @(
        $MediaComposerInstallPaths |
            Where-Object { Test-Path -LiteralPath $_ }
    )

    $VersionText = 'not detected'
    if ($InstalledPaths.Count -gt 0) {
        $VersionInfo = (Get-Item -LiteralPath $InstalledPaths[0]).VersionInfo
        if ($VersionInfo.ProductVersion) {
            $VersionText = $VersionInfo.ProductVersion
        }
    }

    $RunningProcesses = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $AvidProcessNames -contains $_.ProcessName }
    )

    $Metrics = 'installed={0}|running_processes={1}' -f ([int]($InstalledPaths.Count -gt 0)), $RunningProcesses.Count

    if ($InstalledPaths.Count -eq 0) {
        return New-CheckmkLine -State 1 -Name 'CETS Avid Media Composer Application' -Metrics $Metrics -Details 'Avid Media Composer executable was not found in the expected install paths.'
    }

    if ($RunningProcesses.Count -gt 0) {
        $Names = ($RunningProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
        return New-CheckmkLine -State 0 -Name 'CETS Avid Media Composer Application' -Metrics $Metrics -Details "Installed version $VersionText. Running process detected: $Names."
    }

    return New-CheckmkLine -State 0 -Name 'CETS Avid Media Composer Application' -Metrics $Metrics -Details "Installed version $VersionText. Application is not currently open."
}

function Get-AvidEventLine {
    $StartTime = (Get-Date).AddMinutes(-1 * $EventLookbackMinutes)
    $Events = @()

    foreach ($Log in $AvidEventLogs) {
        try {
            $Candidates = @(
                Get-WinEvent -FilterHashtable @{
                    LogName   = $Log
                    StartTime = $StartTime
                    Level     = @(1, 2, 3)
                } -MaxEvents 80 -ErrorAction Stop
            )

            foreach ($Event in $Candidates) {
                $Provider = [string]$Event.ProviderName
                $Message = [string]$Event.Message
                $Haystack = $Provider + ' ' + $Message
                if (
                    (Test-TextContainsAny -Text $Haystack -Patterns $AvidEventPatterns) -and
                    -not (Test-TextContainsAny -Text $Haystack -Patterns $IgnoredEventPatterns)
                ) {
                    $Events += $Event
                }
            }
        }
        catch {
            if ($_.Exception.Message -notmatch 'No events were found') {
                throw
            }
        }
    }

    $UniqueEvents = @(
        $Events |
            Sort-Object TimeCreated -Descending |
            Select-Object -First $MaxRecentEvents
    )

    $Metrics = 'recent_events={0}' -f $UniqueEvents.Count

    if ($UniqueEvents.Count -eq 0) {
        return New-CheckmkLine -State 0 -Name 'CETS Avid Recent Events' -Metrics $Metrics -Details "No Avid/NEXIS/licensing warnings or errors found in the last $EventLookbackMinutes minutes."
    }

    $Details = @(
        $UniqueEvents | ForEach-Object {
            '{0} {1} {2}: {3}' -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $_.LogName, $_.ProviderName, (Escape-CheckmkText -Text $_.Message)
        }
    ) -join ' | '

    return New-CheckmkLine -State 1 -Name 'CETS Avid Recent Events' -Metrics $Metrics -Details "Recent Avid/NEXIS/licensing warning/error events: $Details"
}

function Get-NetworkAdapterLine {
    if (-not (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
        return New-CheckmkLine -State 3 -Name 'CETS Avid Edit Network Adapters' -Details 'Get-NetAdapter is not available on this host.'
    }

    $Adapters = @(
        Get-NetAdapter -ErrorAction Stop |
            Where-Object {
                $AdapterText = $_.Name + ' ' + $_.InterfaceDescription
                Test-TextContainsAny -Text $AdapterText -Patterns $ImportantAdapterPatterns
            }
    )

    $DownAdapters = @(
        $Adapters | Where-Object { $_.Status -ne 'Up' }
    )

    $Metrics = 'matched_adapters={0}|down_adapters={1}' -f $Adapters.Count, $DownAdapters.Count

    if ($Adapters.Count -eq 0) {
        return New-CheckmkLine -State 0 -Name 'CETS Avid Edit Network Adapters' -Metrics $Metrics -Details 'No obvious Avid/NEXIS/edit-network adapter names matched; relying on standard Windows interface checks.'
    }

    if ($DownAdapters.Count -gt 0) {
        $Details = ($DownAdapters | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }) -join ', '
        return New-CheckmkLine -State 1 -Name 'CETS Avid Edit Network Adapters' -Metrics $Metrics -Details "One or more likely edit/NEXIS adapters are not Up: $Details."
    }

    $UpDetails = ($Adapters | ForEach-Object { '{0} {1}' -f $_.Name, $_.LinkSpeed }) -join ', '
    return New-CheckmkLine -State 0 -Name 'CETS Avid Edit Network Adapters' -Metrics $Metrics -Details "Likely edit/NEXIS adapters are Up: $UpDetails."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    if (Test-CacheFresh) {
        Get-Content -LiteralPath $CacheFile
        exit 0
    }

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -Path $CacheDirectory -ItemType Directory -Force | Out-Null
    }

    $Lines = @(
        Get-AvidServiceLine
        Get-AvidApplicationLine
        Get-AvidEventLine
        Get-NetworkAdapterLine
    )

    $Lines | Set-Content -LiteralPath $CacheFile -Encoding ASCII
    $Lines
    exit 0
}
catch {
    $ErrorMessage = Escape-CheckmkText -Text $_.Exception.Message
    New-CheckmkLine -State 3 -Name 'CETS Avid Local Check Runtime' -Details "Local check failed: $ErrorMessage"
    exit 0
}
