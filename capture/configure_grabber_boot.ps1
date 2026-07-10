# configure_grabber_boot.ps1 - one-shot at boot: load the working .ccf into the
# Xtium so it comes up in Full config (D3 green) headless, no CamExpert.
#
# The FPGA keeps the config until the next reboot even after this process exits,
# so this runs once and exits. Retries because the board driver may not be ready
# immediately at boot. Logs to C:\dev\grabber_config.log.
#
# Run at boot by the XylosomeGrabberConfig scheduled task (SYSTEM, 64-bit).

$sap    = "C:\Program Files\Teledyne DALSA\Sapera"
$bin    = "$sap\Components\NET\Bin"
$ccf    = "$sap\CamFiles\User\HS-80-08K80_Full_8tap_8bit_WORKING.ccf"
$server = "Xtium-CL_MX4_1"
$log    = "C:\dev\grabber_config.log"

$env:PATH = "$sap\Bin;$env:PATH"

function Log($m) { "{0}  {1}" -f (Get-Date -Format s), $m | Out-File -FilePath $log -Append -Encoding utf8 }

Log ("--- boot configure start (64-bit={0}) ---" -f [Environment]::Is64BitProcess)

try {
    [void][Reflection.Assembly]::LoadFrom("$bin\DALSA.SaperaLT.SapClassBasic.dll")
} catch {
    Log ("assembly load failed: {0}" -f $_.Exception.Message)
    exit 1
}

$ok = $false
for ($i = 1; $i -le 12; $i++) {
    try {
        $loc = New-Object DALSA.SaperaLT.SapClassBasic.SapLocation($server, 0)
        $acq = New-Object DALSA.SaperaLT.SapClassBasic.SapAcquisition($loc, $ccf)
        if ($acq.Create()) {
            Log ("attempt {0}: Acq.Create() OK - board configured from .ccf" -f $i)
            try { $acq.Destroy() | Out-Null } catch {}   # release handle; FPGA keeps config
            $ok = $true
            break
        } else {
            Log ("attempt {0}: Create() returned false" -f $i)
        }
    } catch {
        Log ("attempt {0}: {1}" -f $i, $_.Exception.Message)
    }
    Start-Sleep -Seconds 5
}

if ($ok) { Log "done - grabber in Full config" } else { Log "FAILED after retries" ; exit 1 }
