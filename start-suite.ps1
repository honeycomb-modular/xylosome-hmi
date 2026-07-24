# Launch the Xylosome Suite viewer against real scans + real camera on the capture PC.
#   pwsh -File start-suite.ps1
# Passive viewer only — never touches the capture agent (see CLAUDE.md / capture_agent.py).
$ErrorActionPreference = "Stop"

$env:PATH        = "C:\msys64\ucrt64\bin;$env:PATH"   # libvips + Qt DLLs
$env:CAPTURE_DIR = "D:/capture"                       # real p0_C TIFFs
$env:XYLOD_HOST  = "192.168.2.2"                      # Beckhoff; suite builds sessions from pass_start/pass_end

$exe = "$PSScriptRoot\build-suite\xylosome-suite.exe"
if (-not (Test-Path $exe)) { throw "not built: $exe" }

# Smart App Control blocks this unsigned local build; fail loudly instead of a bare "Permission denied".
$sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -EA SilentlyContinue).VerifiedAndReputablePolicyState
if ($sac -eq 1) { throw "Smart App Control is ON (enforcement) - it will block $exe. Turn it off (windowsdefender://smartappcontrol) and reboot." }

Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot
