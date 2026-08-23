# harden_capture_pc.ps1 - make the capture PC behave like an appliance:
#   * no automatic Windows Update / no surprise reboots (manual updates still work)
#   * no notification / tips / "finish setup" popups
#   * maximum, steady performance (no core parking, throttling, PCIe/USB power save, no sleep)
#   * verify Windows isn't limiting cores or RAM
# Run as ADMINISTRATOR. Reboot afterwards. Reversal notes inline.

Write-Host "== Windows Update: disable AUTOMATIC (manual still works), no auto-reboot ==" -ForegroundColor Cyan
$au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item $au -Force | Out-Null
Set-ItemProperty $au NoAutoUpdate 1 -Type DWord                     # updates only when you check manually
Set-ItemProperty $au AUOptions 2 -Type DWord                       # 2 = notify, never auto-download/install
Set-ItemProperty $au NoAutoRebootWithLoggedOnUsers 1 -Type DWord   # never reboot on its own
# To fully re-enable Windows Update later: remove the key
#   Remove-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse
# (Home edition may ignore this policy; if updates still nag, disable the service:
#   Stop-Service wuauserv; Set-Service wuauserv -StartupType Disabled )

Write-Host "== Notifications / tips / 'finish setup' popups: OFF ==" -ForegroundColor Cyan
$pn = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
if (-not (Test-Path $pn)) { New-Item $pn -Force | Out-Null }
Set-ItemProperty $pn ToastEnabled 0 -Type DWord -Force
$cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
foreach ($n in "SubscribedContent-338389Enabled","SystemPaneSuggestionsEnabled",
               "SubscribedContent-338388Enabled","SubscribedContent-310093Enabled",
               "SoftLandingEnabled","RotatingLockScreenOverlayEnabled") {
    Set-ItemProperty $cdm $n 0 -Type DWord -ErrorAction SilentlyContinue
}
$upe = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
if (-not (Test-Path $upe)) { New-Item $upe -Force | Out-Null }
Set-ItemProperty $upe ScoobeSystemSettingEnabled 0 -Type DWord -Force  # kills "finish setting up your device"

Write-Host "== Power: High Performance (max CPU, no core parking, PCIe ASPM off), never sleep ==" -ForegroundColor Cyan
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c   # High Performance: CPU 100%, no core parking, PCIe ASPM off
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /h off   # no hibernation, so Fast Startup can never return: the cart's `shutdown /s /f` stays a FULL power-off

Write-Host "== Verify no artificial core/RAM limits (blank below = good) ==" -ForegroundColor Cyan
bcdedit /enum '{current}' | Select-String "numproc|truncatememory|removememory"
Write-Host ("Logical processors Windows sees: {0}" -f [Environment]::ProcessorCount)
Write-Host ("Total RAM (GB): {0}" -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1))

Write-Host "`nDone. Reboot to apply. (Sapera contiguous memory 64 MB is a separate step - see chat.)" -ForegroundColor Green
