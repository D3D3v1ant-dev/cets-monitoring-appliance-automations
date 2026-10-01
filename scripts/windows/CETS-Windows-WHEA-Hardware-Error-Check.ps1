<#
.SYNOPSIS
    CETS - Windows WHEA Hardware Error Check

.DESCRIPTION
    Checks the Windows System event log for Microsoft-Windows-WHEA-Logger
    hardware events during a configurable lookback period.

    Intended for non-interactive execution via Tactical RMM as NT AUTHORITY\SYSTEM.

.EXIT CODES
    0 = PASS - No WHEA events detected
    1 = SCRIPT ERROR - The check could not be completed
    2 = HARDWARE EVENT DETECTED - One or more WHEA events were found
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

$LookbackDays = 7
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
    $StartTime = (Get-Date).AddDays(-$LookbackDays)

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

    if ($Events.Count -eq 0) {
        Write-Output "$Prefix PASS - No WHEA hardware errors found in the last $LookbackDays days."
        exit 0
    }

    Write-Output "$Prefix FAIL - $($Events.Count) WHEA hardware event(s) found in the last $LookbackDays days."
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
