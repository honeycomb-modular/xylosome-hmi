# package-suite.ps1 — build a self-contained Xylosome Suite folder + desktop shortcut.
#
# The Suite is built against msys2 UCRT64 (Qt6 + libvips), so the bare exe only
# runs with C:\msys64\ucrt64\bin on PATH — which is the entire reason
# start-suite.ps1 existed. This collects every DLL, Qt plugin and QML module it
# actually needs into one folder, so it runs from a double-click on a machine
# that has no msys2 at all.
#
#   pwsh -File package-suite.ps1
#
# Re-run it after any rebuild; it refreshes the exe and re-deploys.

param([switch]$NoAutostart)

$ErrorActionPreference = "Stop"

$ucrt = "C:\msys64\ucrt64\bin"
$src  = "$PSScriptRoot\build-suite\xylosome-suite.exe"
$dist = "$PSScriptRoot\dist\XylosomeSuite"

if (-not (Test-Path $src))  { throw "not built: $src  (cmake --build build-suite)" }
if (-not (Test-Path $ucrt)) { throw "msys2 UCRT64 not found at $ucrt" }

New-Item -ItemType Directory -Force -Path $dist | Out-Null
Copy-Item $src $dist -Force
Write-Host "exe -> $dist"

# ── Qt: DLLs, platform plugins, QML modules ───────────────────────────────────
# --qmldir makes it scan our QML for imports, so QtQuick/Controls/Layouts and
# their plugins come along. Without it the app starts and shows a blank window.
# qmlimportscanner lives in share\qt6\bin in the msys2 layout, NOT next to
# windeployqt. Without it on PATH windeployqt dies with a bare
# "Process failed to start" the moment it starts scanning QML.
$env:PATH = "$ucrt;C:\msys64\ucrt64\share\qt6\bin;$env:PATH"
& "$ucrt\windeployqt6.exe" --qmldir "$PSScriptRoot\suite\qml" `
    --no-translations --no-system-d3d-compiler --no-opengl-sw `
    "$dist\xylosome-suite.exe" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed ($LASTEXITCODE)" }
Write-Host "qt   -> deployed"

# ── qt.conf ───────────────────────────────────────────────────────────────────
# Without this Qt resolves plugins and QML imports against the prefix compiled
# into the libraries — C:\msys64\ucrt64\share\qt6 — and ignores everything
# deployed here, which fails on any machine that has no msys2. windeployqt does
# not write one for this layout. Plugins sit at the exe root (platforms\, tls\,
# imageformats\ …), hence Plugins = "." rather than "plugins".
@"
[Paths]
Prefix = .
Plugins = .
Qml2Imports = qml
"@ | Set-Content -Path "$dist\qt.conf" -Encoding ASCII
Write-Host "conf -> qt.conf"

# ── QML module fix-up ─────────────────────────────────────────────────────────
# windeployqt creates a module's sub-directories but can miss the module's OWN
# root files — QtQuick/Controls arrived with every style but without qmldir or
# qtquickcontrols2plugin.dll, which fails at runtime with
#   module "QtQuick.Controls" plugin "qtquickcontrols2plugin" not found
# and nothing but a blank window. Mirror any file the source module has and the
# deployed copy does not.
$qmlSrc = "C:\msys64\ucrt64\share\qt6\qml"
$fixed = 0
Get-ChildItem "$dist\qml" -Recurse -Directory | ForEach-Object {
    $rel = $_.FullName.Substring("$dist\qml".Length).TrimStart('\')
    $from = Join-Path $qmlSrc $rel
    if (-not (Test-Path $from)) { return }
    Get-ChildItem $from -File | ForEach-Object {
        $dst = Join-Path "$dist\qml\$rel" $_.Name
        if (-not (Test-Path $dst)) { Copy-Item $_.FullName $dst -Force; $script:fixed++ }
    }
}
Write-Host "qml  -> $fixed missing module file(s) restored"

# ── everything else (libvips, glib, gcc runtime, …) ───────────────────────────
# windeployqt only knows about Qt. Walk the real import table with ldd and take
# anything that resolves inside the msys2 prefix; Windows' own DLLs stay put.
# objdump reads the real import table, so nothing is guessed. Anything that
# exists in the msys2 prefix gets copied next to the exe; Windows' own DLLs are
# left alone. Iterates to a fixed point because copied DLLs pull in more.
$objdump = "$ucrt\objdump.exe"
$scanned = @{}
function Import-Names([string]$file) {
    $names = @()
    foreach ($line in (& $objdump -p $file 2>$null)) {
        if ($line -match '^\s*DLL Name:\s*(\S+)') { $names += $matches[1] }
    }
    return $names
}
for ($pass = 0; $pass -lt 12; $pass++) {
    $todo = @("$dist\xylosome-suite.exe") +
            (Get-ChildItem $dist -Recurse -Filter *.dll | ForEach-Object { $_.FullName })
    $added = 0
    foreach ($f in $todo) {
        if ($scanned.ContainsKey($f)) { continue }
        $scanned[$f] = $true
        foreach ($n in (Import-Names $f)) {
            if (Test-Path "$dist\$n") { continue }
            if (Test-Path "$ucrt\$n") { Copy-Item "$ucrt\$n" $dist -Force; $added++ }
        }
    }
    if ($added -eq 0) { break }
}
Write-Host ("deps -> {0} dll(s) beside the exe" -f (Get-ChildItem $dist -Filter *.dll).Count)

# ── launcher ──────────────────────────────────────────────────────────────────
# Keeps the rig-specific bits (capture folder, Beckhoff address, the Pi clock
# push and metadata sync) out of the exe, so the same build works elsewhere.
#
# The launcher also refreshes the exe from build-suite when that one is newer.
# Without it this folder is a snapshot: a rebuild never reaches the Startup
# shortcut, so logon keeps opening the build from the last time this script ran
# (which is exactly what happened between 2026-08-09 and 08-11). Only the exe is
# copied — if a rebuild pulls in a NEW dll, re-run package-suite.ps1.
@"
@echo off
REM Xylosome Suite — self-contained launcher. No msys2 on PATH required.
set CAPTURE_DIR=D:/capture
set XYLOD_HOST=192.168.2.2
cd /d "%~dp0"
REM Pick up a newer local build if there is one (/XO = only if source is newer).
if exist "$PSScriptRoot\build-suite\xylosome-suite.exe" robocopy "$PSScriptRoot\build-suite" "%~dp0." xylosome-suite.exe /XO /NJH /NJS /NDL /NFL /NP >nul
REM Same for the side tools. Refreshing only the exe left a stale hdr_merge.py
REM here on 2026-08-11: the Suite ran the packaged copy, which still had a bug
REM already fixed in the repo, and the merge died 8 seconds in.
if exist "$PSScriptRoot\suite\tools\hdr_merge.py" robocopy "$PSScriptRoot\suite\tools" "%~dp0tools" hdr_merge.py /XO /NJH /NJS /NDL /NFL /NP >nul
start "" "%~dp0xylosome-suite.exe" --fullscreen
REM Pi clock + metadata SVG sync (best effort; the Suite runs fine without it)
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0pi-metadata.ps1"
"@ | Set-Content -Path "$dist\XylosomeSuite.cmd" -Encoding ASCII

Copy-Item "$PSScriptRoot\sync-metadata.ps1" "$dist\pi-metadata.ps1" -Force

# The HDR merge runs as a side process, so the tool has to travel with the app.
# SessionStore::mergeHdrSet looks for it at tools\hdr_merge.py beside the exe
# (and in the source tree when running from build-suite).
New-Item -ItemType Directory -Force -Path "$dist\tools" | Out-Null
Copy-Item "$PSScriptRoot\suite\tools\hdr_merge.py" "$dist\tools\" -Force
Write-Host "tools -> hdr_merge.py"

# ── desktop shortcut ──────────────────────────────────────────────────────────
$lnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Xylosome Suite.lnk"
$sh  = New-Object -ComObject WScript.Shell
$s   = $sh.CreateShortcut($lnk)
$s.TargetPath       = "$dist\XylosomeSuite.cmd"
$s.WorkingDirectory = $dist
$s.IconLocation     = "$dist\xylosome-suite.exe,0"
$s.WindowStyle      = 7          # minimised — the .cmd is just a launcher
$s.Description      = "Xylosome review suite"
$s.Save()
Write-Host "shortcut -> $lnk"

# ── start at logon ────────────────────────────────────────────────────────────
# Startup folder, not a scheduled task: the Suite is a GUI app and has to run
# inside the interactive session. (The capture agent is the opposite case — it
# owns hardware and runs as a SYSTEM task with no desktop.)
# Pass -NoAutostart to skip, e.g. when packaging for a machine that should not
# launch it on login.
if (-not $NoAutostart) {
    $startup = [Environment]::GetFolderPath("Startup")
    $auto    = Join-Path $startup "Xylosome Suite.lnk"
    $a = $sh.CreateShortcut($auto)
    $a.TargetPath       = "$dist\XylosomeSuite.cmd"
    $a.WorkingDirectory = $dist
    $a.IconLocation     = "$dist\xylosome-suite.exe,0"
    $a.WindowStyle      = 7
    $a.Description      = "Xylosome review suite (starts at logon)"
    $a.Save()
    Write-Host "autostart -> $auto"
}
Write-Host "done."
