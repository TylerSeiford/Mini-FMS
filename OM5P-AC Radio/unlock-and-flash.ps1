#Requires -RunAsAdministrator
# unlock-and-flash.ps1
# Unlocks FRC-firmware OM5P-AC v2 and flashes stock OpenWrt
#
# Place in same directory as:
#   - fwupgrade.cfg
#   - fwupgrade.cfg.sig
#   - openwrt-24.10.3-ath79-generic-openmesh_om5p-ac-v2-squashfs-sysupgrade.bin
#   - ap51-flash-2025.0-i686-npcap.exe
#   - tftpd64.exe (portable Tftpd64, https://github.com/PJO2/tftpd64)
#
# Requirements:
#   - Windows 11
#   - Npcap installed (comes with Wireshark or FRC Radio Configuration Utility)
#   - Run PowerShell as Administrator

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultOpenWrtBin = "openwrt-24.10.3-ath79-generic-openmesh_om5p-ac-v2-squashfs-sysupgrade.bin"
$DefaultAp51Bin = "ap51-flash-2025.0-i686-npcap.exe"
$RadioIpUnlock = "192.168.100.8"
$RadioIpDefault = "192.168.1.1"
$TftpPort = 69
$Tftpd64Exe = Join-Path $ScriptDir "tftpd64.exe"
$Tftpd64Ini = Join-Path $ScriptDir "Tftpd32.ini"
$AdapterRestored = $false
$OriginalIp = $null
$OriginalPrefix = $null
$OriginalGateway = $null
$ChosenAdapter = $null
$ChosenAdapterNpf = $null
$Tftpd64Process = $null

# Known-working Tftpd32.ini settings, captured from a manually-configured
# session (Settings > TFTP: Security = None so the radio can upload its ART
# backup, option negotiation on, 10s timeout, 30 retransmits, translate Unix
# file names, allow '\' as virtual root). BaseDirectory and LocalIP are
# substituted at run time - LocalIP is pinned to the adapter IP we assign
# for the unlock phase ($RadioIpUnlock).
$Tftpd32IniTemplate = @'
[DHCP]
IP_Pool=
PoolSize=0
BootFile=
DNS=
DNS2=
WINS=
Mask=
Gateway=
Option42=
Option120=
DomainName=
Lease (minutes)=2880
AddOptionNumber1=0
AddOptionValue1=
AddOptionNumber2=0
AddOptionValue2=
AddOptionNumber3=0
AddOptionValue3=
AddOptionNumber4=0
AddOptionValue4=
AddOptionNumber5=0
AddOptionValue5=
AddOptionNumber6=0
AddOptionValue6=
AddOptionNumber7=0
AddOptionValue7=
AddOptionNumber8=0
AddOptionValue8=
AddOptionNumber9=0
AddOptionValue9=
AddOptionNumber10=0
AddOptionValue10=
[TFTPD32]
BaseDirectory={0}
TftpPort=69
Hide=0
WinSize=0
Negociate=1
PXECompatibility=0
DirText=0
ShowProgressBar=1
Timeout=10
MaxRetransmit=30
SecurityLevel=0
UnixStrings=1
Beep=0
VirtualRoot=1
MD5=0
LocalIP={1}
Services=47
TftpLogFile=
SaveSyslogFile=
PipeSyslogMsg=0
LowestUDPPort=0
HighestUDPPort=0
MulticastPort=0
MulticastAddress=
PersistantLeases=1
UnicastBOOTP=0
DHCP Ping=1
DHCP Double Answer=0
DHCP LocalIP=
Max Simultaneous Transfers=100
UseEventLog=0
Console Password=tftpd32
Support for port Option=0
Keep transfer Gui=10
Ignore ack for last TFTP packet=0
Enable IPv6=1
Reduce TFTP Path=0
HttpBaseDirectory=.
'@

# --- Helper functions ---
function Write-Step($step, $total, $message) {
    Write-Host ""
    Write-Host "[$step/$total] $message" -ForegroundColor Cyan
}

function Write-Info($message) {
    Write-Host "      $message" -ForegroundColor White
}

function Write-Success($message) {
    Write-Host "      $message" -ForegroundColor Green
}

function Write-Warn($message) {
    Write-Host "WARNING: $message" -ForegroundColor Yellow
}

function Write-Err($message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
}

function Restore-Adapter {
    if (-not $AdapterRestored -and $null -ne $ChosenAdapter) {
        Write-Host ""
        Write-Host "=== Restoring network adapter ===" -ForegroundColor Cyan
        try {
            $adapter = Get-NetAdapter -Name $ChosenAdapter
            Remove-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute -InterfaceIndex $adapter.InterfaceIndex `
                -Confirm:$false -ErrorAction SilentlyContinue

            if ($OriginalIp) {
                New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                    -IPAddress $OriginalIp `
                    -PrefixLength $OriginalPrefix | Out-Null
                if ($OriginalGateway) {
                    New-NetRoute -InterfaceIndex $adapter.InterfaceIndex `
                        -DestinationPrefix "0.0.0.0/0" `
                        -NextHop $OriginalGateway | Out-Null
                }
                Write-Host "      Adapter restored to $OriginalIp" -ForegroundColor Green
            } else {
                Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Enabled
                Write-Host "      Adapter restored to DHCP" -ForegroundColor Green
            }
        } catch {
            Write-Warn "Could not fully restore adapter: $_"
            Write-Host "      You may need to manually reset your ethernet adapter." `
                -ForegroundColor Yellow
        }
        $AdapterRestored = $true
    }
}

function Stop-Tftpd64 {
    Get-Process -Name "tftpd64" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    $script:Tftpd64Process = $null
}

# --- Banner ---
Clear-Host
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  OM5P-AC FRC Firmware Unlocker & OpenWrt Flasher" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT: Power and cabling" -ForegroundColor Yellow
Write-Host "  Power the radio from the BARREL JACK - do NOT use a passive PoE" `
    -ForegroundColor Yellow
Write-Host "  injector. Passive PoE on the closer port interferes with the" `
    -ForegroundColor Yellow
Write-Host "  data path and prevents the unlock from working." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Connect ethernet to the port CLOSEST to the barrel jack." `
    -ForegroundColor Yellow
Write-Host "  This same port and connection is used for both unlock and flash." `
    -ForegroundColor Yellow
Write-Host ""

# --- Step 1: Prerequisites ---
Write-Step 1 7 "Checking prerequisites..."

$npcap = Get-ItemProperty "HKLM:\SOFTWARE\Npcap" -ErrorAction SilentlyContinue
if ($null -eq $npcap) {
    $npcap = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Npcap" `
        -ErrorAction SilentlyContinue
}
if ($null -eq $npcap) {
    $npcap = Get-Service -Name "npcap" -ErrorAction SilentlyContinue
}
if ($null -eq $npcap) {
    Write-Err "Npcap is not installed."
    Write-Host ""
    Write-Host "      Npcap is required for ap51-flash to access the network adapter." `
        -ForegroundColor White
    Write-Host "      Install it from: https://npcap.com/#download" -ForegroundColor White
    Write-Host "      Or install Wireshark which includes Npcap." -ForegroundColor White
    Write-Host "      The FRC Radio Configuration Utility also installs Npcap." `
        -ForegroundColor White
    exit 1
}
Write-Success "Npcap is installed."

# --- Step 2: File configuration ---
Write-Step 2 7 "File configuration..."
Write-Host ""

$OpenWrtBin = Read-Host "      OpenWrt sysupgrade bin [$DefaultOpenWrtBin]"
if ([string]::IsNullOrWhiteSpace($OpenWrtBin)) { $OpenWrtBin = $DefaultOpenWrtBin }

$Ap51Bin = Read-Host "      ap51-flash binary [$DefaultAp51Bin]"
if ([string]::IsNullOrWhiteSpace($Ap51Bin)) { $Ap51Bin = $DefaultAp51Bin }

# --- Step 3: Preflight checks ---
Write-Step 3 7 "Running preflight checks..."

$RequiredFiles = @("fwupgrade.cfg", "fwupgrade.cfg.sig", $OpenWrtBin, $Ap51Bin, "tftpd64.exe")
$AllFound = $true
foreach ($f in $RequiredFiles) {
    $path = Join-Path $ScriptDir $f
    if (Test-Path $path) {
        Write-Success "Found: $f"
    } else {
        Write-Err "Missing: $f"
        Write-Host "         Place it in: $ScriptDir" -ForegroundColor Red
        $AllFound = $false
    }
}
if (-not $AllFound) { exit 1 }

# Regenerate the tftpd64 config with the known-working settings every run, so
# it can't go stale if this folder is ever moved/renamed.
($Tftpd32IniTemplate -f $ScriptDir, $RadioIpUnlock) | Set-Content -Path $Tftpd64Ini -Encoding ASCII

# Clean up any leftover tftpd64 process from a previous run that didn't exit
# cleanly (e.g. window closed, script interrupted).
Stop-Tftpd64

# --- Step 4: Select network adapter ---
Write-Step 4 7 "Select network adapter..."
Write-Host ""
Write-Host "      Connect the radio's port CLOSEST to the barrel jack to your" `
    -ForegroundColor Yellow
Write-Host "      laptop ethernet port, and power the radio on from the barrel" `
    -ForegroundColor Yellow
Write-Host "      jack (no passive PoE injector)." -ForegroundColor Yellow
Write-Host ""
Write-Host "      Wait for the radio to fully boot (about 60-90 seconds) so its" `
    -ForegroundColor Yellow
Write-Host "      link comes up and the adapter below shows as active." `
    -ForegroundColor Yellow
Write-Host ""
Read-Host "      Press Enter once the radio has finished booting"
Write-Host ""
Write-Info "Available ethernet adapters:"
Write-Host ""

$Adapters = Get-NetAdapter | Where-Object {
    $_.MediaType -eq "802.3" -and $_.Status -eq "Up" }
if ($Adapters.Count -eq 0) {
    Write-Err "No active ethernet adapters found. Plug in your ethernet cable and try again."
    exit 1
}

$i = 1
foreach ($a in $Adapters) {
    Write-Host "      [$i] $($a.Name) - $($a.InterfaceDescription)" -ForegroundColor White
    $i++
}

Write-Host ""
do {
    $selection = Read-Host "      Enter adapter number"
    $selInt = 0
    $valid = [int]::TryParse($selection, [ref]$selInt) -and `
             $selInt -ge 1 -and $selInt -le $Adapters.Count
    if (-not $valid) { Write-Warn "Invalid selection, try again." }
} while (-not $valid)

$ChosenAdapter = $Adapters[$selInt - 1].Name
# ap51-flash uses Npcap and identifies interfaces by device path, not the
# Windows friendly name - build the \Device\NPF_{GUID} path it expects.
$ChosenAdapterNpf = "\Device\NPF_$($Adapters[$selInt - 1].InterfaceGuid)"
$AdapterIndex = $Adapters[$selInt - 1].InterfaceIndex
Write-Success "Using adapter: $ChosenAdapter"

# Save current IP config for restore later
$CurrentIp = Get-NetIPAddress -InterfaceIndex $AdapterIndex `
    -AddressFamily IPv4 -ErrorAction SilentlyContinue
$CurrentGw = Get-NetRoute -InterfaceIndex $AdapterIndex `
    -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
if ($CurrentIp) {
    $OriginalIp = $CurrentIp.IPAddress
    $OriginalPrefix = $CurrentIp.PrefixLength
    Write-Info "Current IP saved: $OriginalIp/$OriginalPrefix"
}
if ($CurrentGw) {
    $OriginalGateway = $CurrentGw.NextHop
    Write-Info "Current gateway saved: $OriginalGateway"
}

# --- Step 5: Unlock phase ---
Write-Step 5 7 "Unlock phase..."

# Set adapter IP
Write-Info "Setting adapter IP to $RadioIpUnlock..."
Remove-NetIPAddress -InterfaceIndex $AdapterIndex `
    -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetRoute -InterfaceIndex $AdapterIndex `
    -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $AdapterIndex `
    -IPAddress $RadioIpUnlock -PrefixLength 24 | Out-Null

# Wait for IP to be fully applied
$ipReady = $false
for ($i = 1; $i -le 15; $i++) {
    $checkIps = Get-NetIPAddress -InterfaceIndex $AdapterIndex `
        -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $found = $false
    if ($checkIps) {
        foreach ($ip in $checkIps) {
            if ($ip.IPAddress -eq $RadioIpUnlock -and $ip.AddressState -eq "Preferred") {
                $found = $true; break
            }
        }
    }
    if ($found) {
        $ipReady = $true
        Write-Success "Adapter IP confirmed: $RadioIpUnlock"
        break
    }
    Write-Info "Waiting for IP assignment... attempt $i/15"
    Start-Sleep -Seconds 2
}
if (-not $ipReady) {
    Write-Err "Adapter IP was not applied within 30 seconds."
    exit 1
}

# Windows still briefly holds the interface even after the address reports
# Preferred (duplicate-address ARP probe settling) - without this, tftpd64
# can launch a split-second too early and fail with WSAEADDRNOTAVAIL (10049).
Start-Sleep -Seconds 2

# Add firewall rule
Write-Info "Adding firewall rule for TFTP (UDP port $TftpPort)..."
Remove-NetFirewallRule -DisplayName "OM5P-AC TFTP" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "OM5P-AC TFTP" `
    -Direction Inbound -Protocol UDP -LocalPort $TftpPort `
    -Action Allow | Out-Null
Write-Success "Firewall rule added."

# Start TFTP server (tftpd64) - it loads Tftpd32.ini from its own directory
Write-Info "Starting TFTP server (tftpd64)..."
$Tftpd64Process = Start-Process -FilePath $Tftpd64Exe -PassThru
Start-Sleep -Seconds 1
if ($Tftpd64Process.HasExited) {
    Write-Err "tftpd64 failed to start."
    Restore-Adapter
    exit 1
}
Write-Success "TFTP server running - a Tftpd64 window has opened."
Write-Info "Watch that window for live transfer activity."

Write-Host ""
Write-Host "      ============================================================" `
    -ForegroundColor Yellow
Write-Host "      UNLOCK PHASE" -ForegroundColor Yellow
Write-Host ""
Write-Host "      Power cycle the radio now (unplug and replug the barrel jack)." `
    -ForegroundColor Yellow
Write-Host ""
Write-Host "      Watch the radio LEDs:" -ForegroundColor White
Write-Host "        Blue LED blinking      = downloading unlocker files" `
    -ForegroundColor White
Write-Host "        Orange/green blinking, or off/green blinking" `
    -ForegroundColor Green
Write-Host "          (depending on the LED's starting color)" -ForegroundColor Green
Write-Host "          = SUCCESS - radio unlocked!" -ForegroundColor Green
Write-Host ""
Write-Host "      An ART backup file (om5p-ac-v2__*.bin) will appear in this" `
    -ForegroundColor White
Write-Host "      script's directory, confirming success." -ForegroundColor White
Write-Host ""
Write-Host "      ALREADY UNLOCKED? Watch the Tftpd64 window: if it shows the" `
    -ForegroundColor Cyan
Write-Host "      radio downloading fwupgrade.cfg but NOT fwupgrade.cfg.sig," `
    -ForegroundColor Cyan
Write-Host "      this radio is already unlocked (it didn't need the exploit" `
    -ForegroundColor Cyan
Write-Host "      payload). No ART backup will appear - press Enter below to" `
    -ForegroundColor Cyan
Write-Host "      skip the wait and continue straight to flashing." -ForegroundColor Cyan
Write-Host "      ============================================================" `
    -ForegroundColor Yellow
Write-Host ""

$ArtBackupFound = $false
$ArtWaitSkipped = $false
Write-Info "Waiting for ART backup file to confirm unlock (up to 3 minutes)."
Write-Info "Press Enter at any time to skip this wait (e.g. already-unlocked radio)."
for ($i = 1; $i -le 90; $i++) {
    $backup = Get-ChildItem -Path $ScriptDir -Filter "om5p-ac-v2__*.bin" -ErrorAction SilentlyContinue
    if ($backup) {
        Write-Success "ART backup found: $($backup[0].Name) - radio unlocked!"
        $ArtBackupFound = $true
        break
    }
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq "Enter") {
            Write-Info "Skipping ART backup wait."
            $ArtWaitSkipped = $true
            break
        }
    }
    Start-Sleep -Seconds 2
}
if (-not $ArtBackupFound -and -not $ArtWaitSkipped) {
    Write-Warn "No ART backup file detected. If this radio was already unlocked, that's expected."
}

if (-not $ArtWaitSkipped) {
    Read-Host "      Press Enter once the radio LED is blinking (unlocked), or Ctrl+C to abort"
}

Stop-Tftpd64
Write-Info "TFTP server stopped."

# Remove firewall rule
Remove-NetFirewallRule -DisplayName "OM5P-AC TFTP" -ErrorAction SilentlyContinue
Write-Info "Firewall rule removed."

Write-Host ""
Write-Info "The unlock permanently wipes the RSA key from flash, so power"
Write-Info "cycling the radio is safe - you'll be prompted to do that once"
Write-Info "ap51-flash is up and ready for it."

# --- Step 6: Flash OpenWrt ---
Write-Step 6 7 "Flashing OpenWrt..."
Write-Host ""

Write-Info "Laptop IP stays at $RadioIpUnlock - no change needed."

$Ap51Path = Join-Path $ScriptDir $Ap51Bin
$OpenWrtPath = Join-Path $ScriptDir $OpenWrtBin

Write-Info "Starting ap51-flash..."

# Run ap51-flash with its own process/pipes (instead of Start-Process -Wait)
# so we can watch its output for the "flash complete" line and stop it
# ourselves - ap51-flash keeps listening indefinitely after a successful
# flash, it never exits on its own.
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Ap51Path
$psi.Arguments = "`"$ChosenAdapterNpf`" `"$OpenWrtPath`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true

$ap51Process = New-Object System.Diagnostics.Process
$ap51Process.StartInfo = $psi
$ap51Process.EnableRaisingEvents = $true

$script:FlashComplete = $false
$outputAction = {
    if ($EventArgs.Data) {
        Write-Host "      $($EventArgs.Data)"
        if ($EventArgs.Data -match "flash complete") {
            $script:FlashComplete = $true
        }
    }
}

$stdoutEvent = Register-ObjectEvent -InputObject $ap51Process -EventName OutputDataReceived -Action $outputAction
$stderrEvent = Register-ObjectEvent -InputObject $ap51Process -EventName ErrorDataReceived -Action $outputAction

$ap51Process.Start() | Out-Null
$ap51Process.BeginOutputReadLine()
$ap51Process.BeginErrorReadLine()

Write-Host ""
Write-Host "      ============================================================" `
    -ForegroundColor Yellow
Write-Host "      FLASH PHASE" -ForegroundColor Yellow
Write-Host ""
Write-Host "      ap51-flash is running and waiting for the radio." -ForegroundColor Yellow
Write-Host "      Power cycle the radio now." -ForegroundColor Yellow
Write-Host ""
Write-Host "      Radio will identify as OM5P-AC and accept firmware without" `
    -ForegroundColor Yellow
Write-Host "      a signature. Using the sysupgrade bin (not factory)." `
    -ForegroundColor Yellow
Write-Host "      ============================================================" `
    -ForegroundColor Yellow
Write-Host ""

$FlashTimeoutSeconds = 180
$elapsed = 0
while (-not $script:FlashComplete -and -not $ap51Process.HasExited -and $elapsed -lt $FlashTimeoutSeconds) {
    Start-Sleep -Seconds 1
    $elapsed++
}
Start-Sleep -Milliseconds 500 # let the last buffered output lines print

if ($script:FlashComplete) {
    Write-Host ""
    Write-Success "Flash complete - device ready to unplug."
} elseif ($ap51Process.HasExited) {
    Write-Host ""
    Write-Warn "ap51-flash exited before reporting completion (exit code $($ap51Process.ExitCode))."
} else {
    Write-Host ""
    Write-Warn "Timed out waiting for ap51-flash to report completion."
}

if (-not $ap51Process.HasExited) {
    Write-Info "Stopping ap51-flash..."
    try { $ap51Process.Kill() } catch {}
    $ap51Process.WaitForExit(5000) | Out-Null
}

Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue
Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
Remove-Job -Name $stdoutEvent.Name -ErrorAction SilentlyContinue
Remove-Job -Name $stderrEvent.Name -ErrorAction SilentlyContinue

# --- Step 7: Verify ---
Write-Step 7 7 "Verifying..."

Restore-Adapter

# Clean up generated config
if (Test-Path $Tftpd64Ini) { Remove-Item $Tftpd64Ini -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Info "Waiting for radio to come back up at $RadioIpDefault..."
Write-Info "This may take up to 60 seconds."
Write-Host ""

$RadioUp = $false
for ($i = 1; $i -le 30; $i++) {
    $ping = Test-Connection -ComputerName $RadioIpDefault `
        -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Success "Radio is up at $RadioIpDefault!"
        $RadioUp = $true
        break
    }
    Write-Info "Attempt $i/30 - not up yet..."
    Start-Sleep -Seconds 2
}

Write-Host ""
if (-not $RadioUp) {
    Write-Warn "Radio did not come up at $RadioIpDefault within 60 seconds."
    Write-Host "      Try connecting manually:" -ForegroundColor White
    Write-Host "        1. Set your ethernet adapter to static IP 192.168.1.100/24" `
        -ForegroundColor White
    Write-Host "        2. Open http://$RadioIpDefault in your browser" -ForegroundColor White
} else {
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host "  SUCCESS!" -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Radio is running stock OpenWrt at $RadioIpDefault" -ForegroundColor White
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "    1. Set your ethernet adapter to static IP 192.168.1.100/24" `
        -ForegroundColor White
    Write-Host "    2. Connect to the LAN port (farthest from barrel jack)" `
        -ForegroundColor White
    Write-Host "    3. Open http://$RadioIpDefault in your browser" -ForegroundColor White
    Write-Host "    4. Default password is blank - set one immediately!" -ForegroundColor Yellow
    Write-Host "    5. Follow the base OpenWrt configuration guide" -ForegroundColor White
    Write-Host "    6. Run configure-robot-radio.sh to set team-specific settings" `
        -ForegroundColor White
    Write-Host ""
}

Write-Host ""
Read-Host "Press Enter to exit"