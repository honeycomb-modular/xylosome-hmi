# sync-metadata.ps1 — keep the Pi's MetadataRecorder exports flowing to the
# capture PC for as long as the Suite is running.
#
# The Suite draws the metadata block from an SVG the Pi exports at the end of a
# scan, paired to a session by the timestamp in its FILENAME (SessionStore::
# pairMetaSvg, +/-10 min of the session start). The Pi cannot write to this PC,
# so without this the SVGs simply never arrive and the block silently never
# appears — which is exactly how it "went away".
#
# Pulling once at launch is not enough: you scan AFTER starting the Suite, so the
# interesting export is always the one that did not exist yet. This polls.
#
# Exits by itself when the Suite closes, so nothing is left running.

param(
    [string]$CaptureDir  = $(if ($env:CAPTURE_DIR) { $env:CAPTURE_DIR } else { "D:/capture" }),
    [string]$Pi          = "hoyte@192.168.10.3",
    [int]   $IntervalSec = 20
)

while (Get-Process -Name xylosome-suite -ErrorAction SilentlyContinue) {
    try {
        # What is already here — never re-copy, the FolderWatcher would re-pair it.
        $have = @{}
        Get-ChildItem $CaptureDir -Filter *.svg -ErrorAction SilentlyContinue |
            ForEach-Object { $have[$_.Name] = $true }

        # Recent only. The archive is ~2000 files, and anything written while the
        # Pi's clock was skewed carries a filename timestamp that can never match
        # a session anyway.
        $remote = ssh -o BatchMode=yes -o ConnectTimeout=5 $Pi `
            "find ~/xylosome_exports -name 'xylosome_*.svg' -mmin -180" 2>$null

        $a = @()
        foreach ($f in $remote) {
            if (-not $f) { continue }
            if (-not $have.ContainsKey((Split-Path $f -Leaf))) { $a += "${Pi}:$f" }
        }
        if ($a.Count -gt 0) {
            # One scp argument per file: a space-joined string is read as ONE
            # filename by Windows OpenSSH and fails with "No such file".
            $n = $a.Count
            $a += "$CaptureDir/"
            & scp -o BatchMode=yes @a 2>$null
            Write-Host "metadata: pulled $n svg(s)"
        }
    } catch { }
    Start-Sleep -Seconds $IntervalSec
}
