# Launch the Xylosome Suite viewer against real scans + real camera on the capture PC.
#   pwsh -File start-suite.ps1
# Passive viewer only — never touches the capture agent (see CLAUDE.md / capture_agent.py).
$ErrorActionPreference = "Stop"

$env:PATH        = "C:\msys64\ucrt64\bin;$env:PATH"   # libvips + Qt DLLs
$env:CAPTURE_DIR = "D:/capture"                       # real p0_C TIFFs
$env:XYLOD_HOST  = "192.168.2.2"                      # Beckhoff; suite builds sessions from pass_start/pass_end

# ── Pi metadata: push the clock, then collect the SVGs ────────────────────────
# The suite pairs a MetadataRecorder SVG to a session by the timestamp in its
# FILENAME, within +/-10 min of the session start (SessionStore::pairMetaSvg).
# The Pi has no internet and no working RTC, so its clock drifts weeks behind and
# every SVG then lands unmatched — which is exactly how the metadata block
# "disappeared". Push PC time first, then pull anything recent.
# Best-effort: the suite is perfectly usable without the Pi, so never block on it.
$pi = "hoyte@192.168.10.3"
try {
    $utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    ssh -o BatchMode=yes -o ConnectTimeout=5 $pi "sudo date -u -s '$utc' >/dev/null; sudo touch /var/lib/systemd/timesync/clock" 2>$null

} catch { Write-Host "clock: Pi unreachable, skipping time push" }

$exe = "$PSScriptRoot\build-suite\xylosome-suite.exe"
if (-not (Test-Path $exe)) { throw "not built: $exe" }

# Smart App Control blocks this unsigned local build; fail loudly instead of a bare "Permission denied".
$sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -EA SilentlyContinue).VerifiedAndReputablePolicyState
if ($sac -eq 1) { throw "Smart App Control is ON (enforcement) - it will block $exe. Turn it off (windowsdefender://smartappcontrol) and reboot." }

Start-Process -FilePath $exe -WorkingDirectory $PSScriptRoot

# Collect the Pi's metadata SVGs for as long as the Suite runs. A one-shot pull
# here would always miss the export you care about — you scan after launching.
Start-Process -FilePath "pwsh" -WindowStyle Hidden -ArgumentList @(
    "-NoProfile", "-File", "$PSScriptRoot\sync-metadata.ps1"
)
