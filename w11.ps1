<#
.SYNOPSIS
  Upgrade the system to W11 by first disabling sleep/hibernate timeouts to avoid mid-upgrade pauses,
  then restoring the original power settings at the end. On success, deletes C:\ProgramData\W11.

.NOTES
  - Requires Administrator.
  - Affects the active power plan only.
  - Does not change display sleep unless you set those explicitly.
  - No UI, no prompts. No automatic reboot (reboot later yourself).
  - Dynamic Update DISABLED by default to avoid 46% stalls.
#>

[CmdletBinding()]
param(
  [string]$Source = "C:\ProgramData\W11\Win11_24H2.iso",
  [ValidateSet("Enable","Disable")]
  [string]$DynamicUpdate = "Disable"
)

# --- Power settings helpers ---
function Get-PowerTimeouts {
  # Returns current Sleep/Hibernate timeouts (minutes) for AC/DC on the active scheme
  # Uses powercfg aliases: SCHEME_CURRENT, SUB_SLEEP, STANDBYIDLE, HIBERNATEIDLE
  $outSleep = powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
  $outHib   = powercfg /q SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE

  $acHexSleep = ($outSleep | Select-String 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)').Matches.Groups[1].Value
  $dcHexSleep = ($outSleep | Select-String 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)').Matches.Groups[1].Value
  $acHexHib   = ($outHib   | Select-String 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)').Matches.Groups[1].Value
  $dcHexHib   = ($outHib   | Select-String 'Current DC Power Setting Index:\s*0x([0-9a-fA-F]+)').Matches.Groups[1].Value

  [pscustomobject]@{
    StandbyTimeoutAC   = if ($acHexSleep) { [Convert]::ToInt32($acHexSleep,16) } else { $null }
    StandbyTimeoutDC   = if ($dcHexSleep) { [Convert]::ToInt32($dcHexSleep,16) } else { $null }
    HibernateTimeoutAC = if ($acHexHib)   { [Convert]::ToInt32($acHexHib,16)   } else { $null }
    HibernateTimeoutDC = if ($dcHexHib)   { [Convert]::ToInt32($dcHexHib,16)   } else { $null }
  }
}

function Set-PowerTimeouts {
  param(
    [Parameter(Mandatory)] [int]$StandbyTimeoutAC,
    [Parameter(Mandatory)] [int]$StandbyTimeoutDC,
    [Parameter(Mandatory)] [int]$HibernateTimeoutAC,
    [Parameter(Mandatory)] [int]$HibernateTimeoutDC
  )
  Write-Host "Setting sleep/hibernate timeouts (AC=$StandbyTimeoutAC/DC=$StandbyTimeoutDC; HibAC=$HibernateTimeoutAC/HibDC=$HibernateTimeoutDC)..."
  powercfg /Change standby-timeout-ac   $StandbyTimeoutAC   | Out-Null
  powercfg /Change standby-timeout-dc   $StandbyTimeoutDC   | Out-Null
  powercfg /Change hibernate-timeout-ac $HibernateTimeoutAC | Out-Null
  powercfg /Change hibernate-timeout-dc $HibernateTimeoutDC | Out-Null
}

function Set-NeverSleep {
  # 0 minutes = Never
  Write-Host "Disabling sleep/hibernate timeouts for AC/DC (setting to Never = 0)..."
  powercfg /Change standby-timeout-ac   0 | Out-Null
  powercfg /Change standby-timeout-dc   0 | Out-Null
  powercfg /Change hibernate-timeout-ac 0 | Out-Null
  powercfg /Change hibernate-timeout-dc 0 | Out-Null
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

  Write-Host "Launching: $SetupExe $($args -join ' ')"
  $p = Start-Process -FilePath $SetupExe -ArgumentList $args -PassThru -Wait
  return $p.ExitCode
}

# ---- main ----
$prevTimeouts = $null
$src = $null
$exit = $null
$w11Folder = "C:\ProgramData\W11"

try {
  # Capture current power timeouts, then set to Never
  try {
    $prevTimeouts = Get-PowerTimeouts
    Write-Host ("Captured current timeouts: Sleep AC/DC = {0}/{1} min, Hibernate AC/DC = {2}/{3} min" -f `
      $prevTimeouts.StandbyTimeoutAC, $prevTimeouts.StandbyTimeoutDC, $prevTimeouts.HibernateTimeoutAC, $prevTimeouts.HibernateTimeoutDC)
  } catch {
    Write-Warning "Could not capture existing power timeouts: $($_.Exception.Message)"
  }

  try { Set-NeverSleep } catch { Write-Warning "Failed to set NeverSleep: $($_.Exception.Message)" }

  # Resolve source & run upgrade
  $src  = Resolve-SetupSource -Source $Source
  $exit = Start-Upgrade -SetupExe $src.Setup -DynamicUpdate $DynamicUpdate

  # Record status; do NOT close the console or reboot
  $statusPath = Join-Path -Path $env:SystemDrive -ChildPath "Win11SetupLogs\status.txt"
  "[{0}] ExitCode={1} (DynamicUpdate={2})" -f (Get-Date -Format s), $exit, $DynamicUpdate |
    Out-File -FilePath $statusPath -Encoding UTF8 -Append

  $global:LASTEXITCODE = $exit
  Write-Output "Setup ExitCode=$exit (DynamicUpdate=$DynamicUpdate). Reboot later to continue upgrade."
}
finally {
  # Always dismount the ISO if we mounted it
  try {
    if ($src -and $src.Mount) { Dismount-DiskImage -ImagePath $Source | Out-Null }
  } catch {
    Write-Warning "Failed to dismount ISO: $($_.Exception.Message)"
  }

  # Restore prior power timeouts if we captured them
  try {
    if ($prevTimeouts -and $prevTimeouts.StandbyTimeoutAC -ne $null) {
      Set-PowerTimeouts `
        -StandbyTimeoutAC   $prevTimeouts.StandbyTimeoutAC `
        -StandbyTimeoutDC   $prevTimeouts.StandbyTimeoutDC `
        -HibernateTimeoutAC $prevTimeouts.HibernateTimeoutAC `
        -HibernateTimeoutDC $prevTimeouts.HibernateTimeoutDC
      Write-Host "Restored previous power timeouts."
    } else {
      Write-Warning "Previous power timeouts unknown; leaving current settings in place."
    }
  } catch {
    Write-Warning "Failed to restore power timeouts: $($_.Exception.Message)"
  }

  # If setup succeeded (ExitCode 0), remove the W11 folder
  try {
    if ($exit -eq 0 -and (Test-Path -LiteralPath $w11Folder)) {
      Write-Host "Upgrade reported success (ExitCode 0). Removing $w11Folder ..."
      Remove-Item -LiteralPath $w11Folder -Recurse -Force -ErrorAction Stop
      Write-Host "Removed $w11Folder."
    }
  } catch {
    Write-Warning "Failed to remove w11 Folder: $($_.Exception.Message)"
  }
}
