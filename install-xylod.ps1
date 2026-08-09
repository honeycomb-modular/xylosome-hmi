# install-xylod.ps1 — install the freshly built xylod on the C6920 and restart it.
#
#   pwsh -File install-xylod.ps1
#
# Exists because the install/restart one-liners are long, contain quotes and a
# semicolon, and pasting them into PowerShell kept dragging the previous
# terminal output in with them. Run this instead; it prompts for the C6920's
# sudo password twice (install, then restart) — that box is NOT NOPASSWD.
#
# Verifies the checksum matches the build before restarting, so a failed copy
# cannot masquerade as a successful deploy the way it did on 2026-08-09.

$ErrorActionPreference = "Stop"
$box  = "hoyte@192.168.2.2"
$key  = "$HOME\.ssh\id_ed25519"
$src  = "/tmp/xylobuild/beckhoff/xylod/build/xylod"
$dst  = "/usr/local/bin/xylod"

Write-Host "== installing $src -> $dst ==" -ForegroundColor Cyan
ssh -t -i $key $box "sudo install -m755 $src $dst"

Write-Host "== checksums ==" -ForegroundColor Cyan
$sums = ssh -i $key $box "md5sum $dst $src"
$sums
$hashes = $sums | ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -Unique
if ($hashes.Count -ne 1) {
    Write-Host "MISMATCH — install did not take. Not restarting." -ForegroundColor Red
    exit 1
}
Write-Host "match: $hashes" -ForegroundColor Green

Write-Host "== restarting xylod ==" -ForegroundColor Cyan
ssh -t -i $key $box "sudo systemctl restart xylod"

Start-Sleep -Seconds 3
Write-Host "== state ==" -ForegroundColor Cyan
ssh -i $key $box "systemctl is-active xylod; journalctl -u xylod --no-pager -n 6 | tail -4"
