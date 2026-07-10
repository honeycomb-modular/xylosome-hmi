# test_camera_client.ps1 - acts as the HMI: connects to the capture agent's
# camera bus, says hello, reads state, sets tdi.stages to 48 then back to 32,
# and prints every reply. Run in a SECOND window while capture_agent.py runs.

$c = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 5521)
$s = $c.GetStream()
$s.ReadTimeout = 3000
$r = New-Object System.IO.StreamReader($s)
$w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true

$w.WriteLine('{"cmd":"hello","client":"test"}')
$w.WriteLine('{"cmd":"get"}')
$w.WriteLine('{"cmd":"set","key":"tdi.stages","value":48}')
$w.WriteLine('{"cmd":"set","key":"tdi.stages","value":32}')

# expect 6 lines: welcome, state, ack+state (48), ack+state (32)
for ($i = 0; $i -lt 6; $i++) {
  try { Write-Host $r.ReadLine() } catch { break }
}
$c.Close()
