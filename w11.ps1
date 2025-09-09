<#
.SYNOPSIS
  Upgrade the system to W11 by first Disabling system sleep on both AC power (plugged in) and DC power (battery) to send the necessary commands to upgrade the PC to W11.

.NOTES
  - Requires Administrator.
  - Affects the active power plan only.
  - Does not disable display sleep/turn off unless you also set those explicitly.
  - No UI, no prompts
  - No automatic reboot (reboot later yourself)
  - Dynamic Update DISABLED by default to avoid 46% stalls
#>

[CmdletBinding()]
param(
  [string]$Source = "C:\ProgramData\W11\Win11_24H2.iso",
  [ValidateSet("Enable","Disable")]
  [string]$DynamicUpdate = "Disable"
)

# --- NEW: helpers to capture/restore power timeouts and remove W11 folder ---
# GUIDs for Sleep/Hibernate timeouts
$script:SUB_SLEEP_GUID     = '238C9FA8-0AAD-41ED-83F4-97BE242C8F20'
$script:SLEEP_AFTER_GUID   = '29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA'
$script:HIBERNATE_AFTER_GUID = '9D7815A6-7EE4-497E-8888-515A05F02364'

$script:PrevPower = $null

function Get-ActiveSchemeGuid {
  # Returns only the GUID of the active scheme
  $line = (powercfg /GetActiveScheme)
  return ($line -replace '.*:\s*','').Split()[0]
}

function Get-CurrentPowerTimeouts {
  param([Parameter(Mandatory=$true)][string]$SchemeGuid)

  function Parse-Idx([string]$s) {
    if ($s -match '0x[0-9A-Fa-f]+') { return [int]([Convert]::ToInt32(($matches[0] -replace '^0x',''),16)) }
    elseif ($s -match '\d+')       { return [int]$matches[0] }
    else                           { return $null }
  }

  $sa = Parse-Idx (powercfg -getacvalueindex $SchemeGuid $script:SUB_SLEEP_GUID $script:SLEEP_AFTER_GUID 2>&1)
  $sd = Parse-Idx (powercfg -getdcvalueindex $SchemeGuid $script:SUB_SLEEP_GUID $script:SLEEP_AFTER_GUID 2>&1)
  $ha = Parse-Idx (powercfg -getacvalueindex $SchemeGuid $script:SUB_SLEEP_GUID $script:HIBERNATE_AFTER_GUID 2>&1)
  $hd = Parse-Idx (powercfg -getdcvalueindex $SchemeGuid $script:SUB_SLEEP_GUID $script:HIBERNATE_AFTER_GUID 2>&1)

  [PSCustomObject]@{ SleepAC=$sa; SleepDC=$sd; HibernateAC=$ha; HibernateDC=$hd }
}

function Restore-PowerTimeouts {
  param([Parameter(Mandatory=$true)]$Prev)

  try {
    if ($Prev.SleepAC      -ne $null) { powercfg /Change standby-timeout-ac   $Prev.SleepAC      | Out-Null }
    if ($Prev.SleepDC      -ne $null) { powercfg /Change standby-timeout-dc   $Prev.SleepDC      | Out-Null }
    if ($Prev.HibernateAC  -ne $null) { powercfg /Change hibernate-timeout-ac $Prev.HibernateAC  | Out-Null }
    if ($Prev.HibernateDC  -ne $null) { powercfg /Change hibernate-timeout-dc $Prev.HibernateDC  | Out-Null }
    Write-Host "Restored previous sleep/hibernate timeouts."
  } catch {
    Write-Warning "Failed to restore previous power timeouts: $_"
  }
}

function Remove-W11Folder {
  param([Parameter(Mandatory=$true)][string]$SourcePath)
  try {
    $parent = Split-Path -Path $SourcePath -Parent
    if ($parent -and (Test-Path -LiteralPath $parent)) {
      $leaf = Split-Path -Path $parent -Leaf
      if ($leaf -ieq 'W11' -and $parent.Length -gt 6) {
        Write-Host "Removing folder '$parent'..."
        Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction Stop
      } else {
        Write-Host "Skip deleting '$parent' (not a 'W11' folder)."
      }
    }
  } catch {
    Write-Warning "Could not remove W11 folder: $_"
  }
}
# --- END NEW helpers ---

function Set-NeverSleep {
    # Get and save current values (NEW)
    try {
        $schemeGuidOnly = Get-ActiveSchemeGuid
        $script:PrevPower = Get-CurrentPowerTimeouts -SchemeGuid $schemeGuidOnly
    } catch {
        Write-Warning "Could not capture current power settings: $_"
    }

    # Get the active power scheme GUID (your original)
    $schemeGuid = (powercfg /GetActiveScheme) -replace '.*:\s*',''
    Write-Host "Active Power Scheme: $schemeGuid"

    # 0 = Never
    Write-Host "Disabling sleep on AC (plugged in)..."
    powercfg /Change standby-timeout-ac 0

    Write-Host "Disabling sleep on DC (battery)..."
    powercfg /Change standby-timeout-dc 0

    # Optional: also disable hibernate timeout if desired
    Write-Host "Disabling hibernate timeout on AC/DC..."
    powercfg /Change hibernate-timeout-ac 0
    powercfg /Change hibernate-timeout-dc 0

    Write-Host "Sleep and hibernate timeouts set to Never."
}
 
function Resolve-SetupSource {
  param([string]$Source)
 
  $mount = $null
  $root  = $null
 
  if (-not (Test-Path -LiteralPath $Source)) {
    throw "Source path not found: $Source"
  }
 
  if ($Source -match '\.iso$') {
    $img = Mount-DiskImage -ImagePath $Source -PassThru -ErrorAction Stop
    $vol = Get-Volume -DiskImage $img | Where-Object DriveLetter | Select-Object -First 1
    if (-not $vol) { throw "Could not resolve mounted ISO volume/drive letter." }
    $root = ($vol.DriveLetter + ":\")
    $mount = $img
  } else {
    $root = (Resolve-Path -LiteralPath $Source).Path
  }
 
  $setupExe = Join-Path -Path $root -ChildPath "setup.exe"
  if (-not (Test-Path -LiteralPath $setupExe)) {
    throw "setup.exe not found in '$root'. Provide an ISO or a folder that contains setup.exe."
  }
 
  [PSCustomObject]@{ Root = $root; Mount = $mount; Setup = $setupExe }
}
 
function Start-Upgrade {
  param(
    [string]$SetupExe,
    [string]$DynamicUpdate
  )
 
  $logDir = "$env:SystemDrive\Win11SetupLogs"
  New-Item -Path $logDir -ItemType Directory -Force | Out-Null
 
  # Fully silent, no UI, no auto-reboot; Dynamic Update default = Disable
  $args = @(
    "/auto","upgrade",
    "/quiet",
    "/eula","accept",
    "/noreboot",
    "/DynamicUpdate",$DynamicUpdate,
    "/Telemetry","Disable",
    "/copylogs",$logDir
  )
 
  $p = Start-Process -FilePath $SetupExe -ArgumentList $args -PassThru -Wait
  return $p.ExitCode
}
 
# ---- main ----

try {
    Set-NeverSleep
} catch {
    Write-Error $_
}

$src = $null
try {
  $src = Resolve-SetupSource -Source $Source
  $exit = Start-Upgrade -SetupExe $src.Setup -DynamicUpdate $DynamicUpdate
 
  # Record status; do NOT close the console or reboot
  $statusPath = Join-Path -Path $env:SystemDrive -ChildPath "Win11SetupLogs\status.txt"
  "[{0}] ExitCode={1} (DynamicUpdate={2})" -f (Get-Date -Format s), $exit, $DynamicUpdate |
    Out-File -FilePath $statusPath -Encoding UTF8 -Append
 
  $global:LASTEXITCODE = $exit
  Write-Output "Setup ExitCode=$exit (DynamicUpdate=$DynamicUpdate). Reboot later to continue upgrade."
}
finally {
  try {
    if ($src -and $src.Mount) { Dismount-DiskImage -ImagePath $Source | Out-Null }
  } catch { }

  # NEW: restore previous timeouts (always attempt)
  if ($script:PrevPower) {
    Restore-PowerTimeouts -Prev $script:PrevPower
  }

  # NEW: remove the 'W11' folder that contains the ISO/source (if applicable)
  Remove-W11Folder -SourcePath $Source
}
