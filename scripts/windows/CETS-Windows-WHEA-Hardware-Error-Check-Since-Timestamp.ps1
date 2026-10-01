<#
.SYNOPSIS
    CETS - Windows WHEA Hardware Error Check - Since Timestamp

.DESCRIPTION
    Checks the Windows System event log for Microsoft-Windows-WHEA-Logger
    hardware events occurring after a configured ISO 8601 local timestamp.

    Intended for targeted post-change validation, such as checking for new WHEA
    events after replacing a GPU, NIC, DIMM configuration, or other hardware.

    Intended for non-interactive execution via Tactical RMM as NT AUTHORITY\SYSTEM.

.EXIT CODES
    0 = PASS - No WHEA events detected since the configured timestamp
    1 = SCRIPT ERROR - The check could not be completed
    2 = HARDWARE EVENT DETECTED - One or more WHEA events were found
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Use ISO 8601 local time to avoid locale-dependent parsing.
# Current value matches the A4000 installation validation window for barcode 118001.
$StartTimeIso = '2026-09-30T14:00:00'

$ProviderName = 'Microsoft-Windows-WHEA-Logger'
$LogName = 'System'
$Prefix = '[WHEA CHECK]'

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

function Get-WheaCategory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $NormalisedMessage = $Message.ToLowerInvariant()

    if ($NormalisedMessage -match 'memory|ecc') {
        return 'Memory / ECC related error'
    }

    if ($NormalisedMessage -match 'pci express|pcie|legacy endpoint') {
        return 'PCI Express hardware error'
    }

    if ($NormalisedMessage -match 'machine check') {
        return 'Machine Check Exception'
    }

    if ($NormalisedMessage -match 'processor|cache') {
        return 'Processor / cache related error'
    }

    if ($NormalisedMessage -match 'corrected hardware error') {
        return 'Corrected hardware error'
    }

    return 'Unknown WHEA hardware event'
}

function Write-WheaEvent {
    param(
        [Parameter(Mandatory = $true)]
        $Event
    )

    $Message = [string]$Event.Message
    $FlattenedMessage = ($Message -replace '\r?\n', ' ' -replace '\s{2,}', ' ').Trim()
    $Category = Get-WheaCategory -Message $Message

    Write-Output "$Prefix EVENT"
    Write-Output "TimeCreated      : $($Event.TimeCreated.ToString('dd/MM/yyyy HH:mm:ss'))"
    Write-Output "Id               : $($Event.Id)"
    Write-Output "LevelDisplayName : $($Event.LevelDisplayName)"
    Write-Output "Category         : $Category"
    Write-Output "Message          : $FlattenedMessage"
    Write-Output ''
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

try {
    $StartTime = [datetime]::ParseExact(
        $StartTimeIso,
        'yyyy-MM-ddTHH:mm:ss',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    try {
        $Events = @(
            Get-WinEvent -FilterHashtable @{
                LogName      = $LogName
                ProviderName = $ProviderName
                StartTime    = $StartTime
            } -ErrorAction Stop
        )
    }
    catch {
        # Get-WinEvent throws when no matching events exist. That condition is
        # a clean PASS, not a script failure.
        if ($_.Exception.Message -match 'No events were found that match the specified selection criteria') {
            $Events = @()
        }
        else {
            throw
        }
    }

    $DisplayStartTime = $StartTime.ToString('dd/MM/yyyy HH:mm')

    if ($Events.Count -eq 0) {
        Write-Output "$Prefix PASS - No WHEA hardware errors found since $DisplayStartTime."
        exit 0
    }

    Write-Output "$Prefix FAIL - $($Events.Count) WHEA hardware event(s) found since $DisplayStartTime."
    Write-Output ''

    $Events |
        Sort-Object TimeCreated -Descending |
        ForEach-Object {
            Write-WheaEvent -Event $_
        }

    exit 2
}
catch {
    $ErrorMessage = ($_.Exception.Message -replace '\r?\n', ' ').Trim()
    Write-Output "$Prefix ERROR - $ErrorMessage"
    exit 1
}
