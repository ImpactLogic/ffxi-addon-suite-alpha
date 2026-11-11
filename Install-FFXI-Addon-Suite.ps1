# FFXI Addon Suite installer. Run it with Install-FFXI-Addon-Suite.bat (double-click).
# It copies the add-on folders from the "addons" folder next to this file into Windower4\addons.
# It never deletes anything and never touches a "data" folder or a settings file.
# Optional parameters (used by the offline test): -WindowerPath <folder>  -Unattended

param(
    [string]$WindowerPath = '',
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $here 'addons'

function Say($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Finish($code) {
    if (-not $Unattended) { Write-Host ''; Read-Host 'Press Enter to close this window' | Out-Null }
    exit $code
}
function Test-Windower($path) {
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $path 'addons'))) { return $false }
    return (Test-Path -LiteralPath (Join-Path $path 'Windower.exe')) -or (Test-Path -LiteralPath (Join-Path $path 'plugins'))
}

Say ''
Say 'FFXI Addon Suite installer' 'Cyan'
Say '--------------------------'

try {
    if (-not (Test-Path -LiteralPath (Join-Path $source 'bags\bags.lua'))) {
        throw "I cannot find the 'addons' folder next to this installer. Unzip the whole download first (right-click the ZIP, Extract All), then double-click the installer inside the unzipped folder."
    }

    # 1. Find Windower.
    $target = ''
    if ($WindowerPath) {
        if (-not (Test-Windower $WindowerPath)) { throw "'$WindowerPath' does not look like a Windower4 folder (it needs an 'addons' folder and Windower.exe)." }
        $target = $WindowerPath
    } else {
        $guesses = @()
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:SystemDrive + '\', $env:USERPROFILE, (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Desktop'))) {
            if ($root) { foreach ($name in @('Windower4', 'Windower')) { $guesses += (Join-Path $root $name) } }
        }
        $found = @($guesses | Where-Object { Test-Windower $_ } | Select-Object -Unique)
        if ($found.Count -ge 1) {
            Say "Found Windower at: $($found[0])" 'Green'
            $answer = Read-Host 'Press Enter to install there, or type N to pick a different folder'
            if ($answer -notmatch '^[nN]') { $target = $found[0] }
        } else {
            Say 'I could not find Windower on its own.' 'Yellow'
        }
        while (-not $target) {
            Say 'A window will open. Pick your Windower4 folder (the one that contains Windower.exe and an "addons" folder).' 'Yellow'
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Pick your Windower4 folder (it contains Windower.exe and an addons folder)'
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw 'No folder picked, so nothing was installed.' }
            if (Test-Windower $dialog.SelectedPath) { $target = $dialog.SelectedPath }
            else { Say "That folder does not have an 'addons' folder and Windower.exe in it. Try again." 'Red' }
        }
    }
    $dest = Join-Path $target 'addons'

    # 2. Can we write there? (Program Files often needs 'Run as administrator'.)
    $probe = Join-Path $dest '.ffxi-suite-write-test'
    try { Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop; Remove-Item -LiteralPath $probe -Force }
    catch { throw "Windows will not let me write to $dest. Close this window, right-click Install-FFXI-Addon-Suite.bat, choose 'Run as administrator', and try again." }

    # 3. Copy every add-on folder. robocopy adds and replaces files; it never deletes anything.
    $names = @(Get-ChildItem -LiteralPath $source -Directory | Select-Object -ExpandProperty Name)
    Say ''
    Say "Copying $($names.Count) add-on folders to $dest ..."
    foreach ($name in $names) {
        & robocopy (Join-Path $source $name) (Join-Path $dest $name) /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copying '$name' failed (robocopy code $LASTEXITCODE). Close Windower and the game, then try again." }
    }

    # 4. Check that it worked.
    $missing = @()
    foreach ($name in $names) { if (-not (Test-Path -LiteralPath (Join-Path $dest "$name\$name.lua"))) { $missing += $name } }
    if ($missing.Count -gt 0) { throw "These folders did not arrive: $($missing -join ', '). Nothing else is wrong; try the installer again." }
    Say "Installed: $($names -join ', ')" 'Green'

    # 5. Offer to load Checkup at every game start.
    $scripts = Join-Path $target 'scripts'
    $init = Join-Path $scripts 'init.txt'
    $line = 'lua load checkup'
    $has = (Test-Path -LiteralPath $init) -and ((Get-Content -LiteralPath $init -ErrorAction SilentlyContinue) -match '^\s*lua\s+(load|l)\s+checkup\s*$')
    if ($has) {
        Say 'scripts\init.txt already loads Checkup at game start.' 'Green'
    } else {
        $ask = 'Y'
        if (-not $Unattended) { $ask = Read-Host "Load Checkup every time you start the game? This adds the line '$line' to scripts\init.txt [Y/n]" }
        if ($ask -notmatch '^[nN]') {
            if (-not (Test-Path -LiteralPath $scripts)) { New-Item -ItemType Directory -Path $scripts | Out-Null }
            $text = ''
            if (Test-Path -LiteralPath $init) { $text = [System.IO.File]::ReadAllText($init); if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`r`n" } }
            [System.IO.File]::WriteAllText($init, $text + $line + "`r`n", (New-Object System.Text.ASCIIEncoding))
            Say "Added '$line' to $init" 'Green'
        } else {
            Say "Skipped. Add the line '$line' to $init yourself if you want Checkup to load at game start." 'Yellow'
        }
    }

    Say ''
    Say 'Done. Next, in the game:' 'Cyan'
    Say '  1. Start (or restart) the game. If it is already running, type  //lua l checkup'
    Say '  2. Type  //setup  to pick what to load, or  //lua l bags  then  //bags layout compact  to start with Bags.'
    Say '  3. Combat recording is OFF until you turn it on (read the notice in the README first).'
    Finish 0
}
catch {
    Say ''
    Say "Problem: $($_.Exception.Message)" 'Red'
    Say 'Nothing was deleted. You can also copy the folders inside "addons" into Windower4\addons by hand.' 'Yellow'
    Finish 1
}
