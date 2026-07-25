# set_exposure.ps1 - brighten the camera via the settings agent (:5521).
# Slower line rate = more exposure per line; more TDI stages = more sensitivity.
# Both are volatile (revert on camera power cycle) - tune freely.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File set_exposure.ps1
#   powershell -ExecutionPolicy Bypass -File set_exposure.ps1 -LineRate 14000 -Stages 64
#
# Requires the settings agent running (scheduled task XylosomeCaptureAgent),
# which owns COM3 and serves :5521.

param(
    [int]$LineRate = 7000,   # Hz, 3500..38314 at 12-bit (lower = slower/brighter)
    [int]$Stages   = 96      # 16/32/48/64/80/96 (higher = more sensitive)
)

$c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 5521)
$s = $c.GetStream(); $s.ReadTimeout = 2000
$r = New-Object System.IO.StreamReader($s)
$w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true

$w.WriteLine('{"cmd":"set","key":"tdi.stages","value":' + $Stages + '}')
$w.WriteLine('{"cmd":"set","key":"line.rate","value":' + $LineRate + '}')
$w.WriteLine('{"cmd":"get"}')
Start-Sleep -Seconds 2
try { while ($true) { Write-Host $r.ReadLine() } } catch {}
$c.Close()
