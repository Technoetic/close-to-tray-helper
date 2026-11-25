#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $AppDir = (Join-Path $env:LOCALAPPDATA 'CloseToTrayHelper\app'),
    [string[]] $SkillsDir,
    [string] $StartupDir = '',
    [switch] $AppOnly,
    [switch] $SkipSkills,
    [switch] $KeepPrefs,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$manifestName = '.close-to-tray-bundle.json'

function Get-FullPath([string] $Path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Get-CheckedAttributes([string] $Path, [switch] $Directory, [string] $StopAt = '') {
    $normPath = Get-FullPath $Path
    $normStop = if ($StopAt) { Get-FullPath $StopAt } else { '' }
    if ($normStop -and $normPath.Equals($normStop, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    $parent = [IO.Path]::GetDirectoryName($normPath)
    if ($parent -and (-not $normStop -or -not $parent.Equals($normStop, [StringComparison]::OrdinalIgnoreCase))) {
        $null = Get-CheckedAttributes -Path $parent -Directory -StopAt $normStop
    }
    try { $attributes = [IO.File]::GetAttributes($normPath) }
    catch [IO.FileNotFoundException] { return }
    catch [IO.DirectoryNotFoundException] { return }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Linked path requires manual review: $normPath"
    }
    if ([bool]($attributes -band [IO.FileAttributes]::Directory) -ne $Directory.IsPresent) {
        throw "Unexpected file or directory: $normPath"
    }
    return $attributes
}

function Get-Digest([string] $Path, [string] $StopAt = '') {
    if ($null -ne (Get-CheckedAttributes -Path $Path -StopAt $StopAt)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $fs = [IO.File]::OpenRead($Path)
            try {
                return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '')
            } finally {
                $fs.Dispose()
            }
        } finally {
            $sha.Dispose()
        }
    }
}

function Remove-EmptyDirsUpTo([string] $Dir, [string] $StopAt) {
    $cur = Get-FullPath $Dir
    $stop = Get-FullPath $StopAt
    while ($cur -and -not $cur.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not (Test-Path -LiteralPath $cur -PathType Container)) { break }
        $items = @(Get-ChildItem -LiteralPath $cur -Force)
        if ($items.Count -gt 0) { break }
        Remove-Item -LiteralPath $cur -Force
        $cur = [IO.Path]::GetDirectoryName($cur)
    }
}

function New-UninstallPlan($Kind, $TargetDir) {
    $stopAt = [IO.Path]::GetDirectoryName($TargetDir)
    if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
        return $null
    }
    $null = Get-CheckedAttributes -Path $TargetDir -Directory -StopAt $stopAt
    $manifest = Join-Path $TargetDir $manifestName
    $manifestHash = Get-Digest $manifest $stopAt
    if (-not $manifestHash) {
        return $null
    }
    $state = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))
    if (@($state.psobject.Properties).Count -ne 2 -or $state.format -cne "close-to-tray-helper/$Kind/1" -or
        $null -eq $state.files) {
        throw "Unrecognized install manifest: $manifest"
    }
    $toDelete = @()
    foreach ($prop in $state.files.psobject.Properties) {
        $name = $prop.Name
        $known = @($prop.Value)
        if ($known.Count -lt 1 -or $known.Count -gt 2 -or
            @($known | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[0-9A-Fa-f]{64}$' }).Count) {
            throw "Invalid hashes in install manifest: $manifest"
        }
        $filePath = Join-Path $TargetDir $name
        $curHash = Get-Digest $filePath $stopAt
        if ($curHash) {
            if (-not $Force.IsPresent -and $curHash -notin $known) {
                throw "Locally edited file requires manual review (re-run with -Force to remove): $filePath"
            }
            $toDelete += $filePath
        }
    }
    return [pscustomobject]@{
        Kind = $Kind
        TargetDir = $TargetDir
        StopAt = $stopAt
        Manifest = $manifest
        Files = $toDelete
    }
}

function Invoke-UninstallPlan($Plan) {
    foreach ($f in $Plan.Files) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            Remove-Item -LiteralPath $f -Force
            Remove-EmptyDirsUpTo ([IO.Path]::GetDirectoryName($f)) $Plan.TargetDir
        }
    }
    if (Test-Path -LiteralPath $Plan.Manifest -PathType Leaf) {
        Remove-Item -LiteralPath $Plan.Manifest -Force
    }
    Remove-EmptyDirsUpTo $Plan.TargetDir $Plan.StopAt
}

function Test-HelperRunning {
    $m = $null
    try {
        if ([Threading.Mutex]::TryOpenExisting('Local\Close-To-Tray-Helper', [ref]$m)) {
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($m) { $m.Dispose() }
    }
}

$mutex = $null
$locked = $false
try {
    $mutex = [Threading.Mutex]::new($false, 'Local\CloseToTrayHelper.Bundle.Install')
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another bundle installation or uninstallation is already running.' }

    $app = Get-FullPath $AppDir
    $skipSkills = $AppOnly.IsPresent -or $SkipSkills.IsPresent
    $skillTargets = @()
    if (-not $skipSkills) {
        if (-not $SkillsDir) {
            $codex = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.agents' }
            $claude = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
            $SkillsDir = @(
                (Join-Path $codex 'skills')
                (Join-Path $claude 'skills')
                (Join-Path $env:USERPROFILE '.gemini\config\skills')
            )
        }
        $skillTargets = @($SkillsDir | Where-Object { $_ } | ForEach-Object {
            Join-Path (Get-FullPath $_) 'aside-repl'
        } | Sort-Object -Unique)
    }

    # Preflight all targets before deleting anything (skills first, then app).
    $plans = @()
    foreach ($target in $skillTargets) {
        $sp = New-UninstallPlan 'aside-repl' $target
        if ($sp) { $plans += $sp }
    }
    $appPlan = New-UninstallPlan 'app' $app
    if ($appPlan) { $plans += $appPlan }

    # Release any working-directory handle inside the app or helper root before deletion.
    $parentRoot = [IO.Path]::GetDirectoryName($app)
    $defaultHelperRoot = Get-FullPath (Join-Path $env:LOCALAPPDATA 'CloseToTrayHelper')
    $isDefaultAppRoot = ($parentRoot -and $parentRoot.Equals($defaultHelperRoot, [StringComparison]::OrdinalIgnoreCase))
    $curDir = Get-FullPath ([Environment]::CurrentDirectory)
    $inApp = $curDir.Equals($app, [StringComparison]::OrdinalIgnoreCase) -or $curDir.StartsWith(($app + '\'), [StringComparison]::OrdinalIgnoreCase)
    $inDefaultRoot = $isDefaultAppRoot -and ($curDir.Equals($parentRoot, [StringComparison]::OrdinalIgnoreCase) -or $curDir.StartsWith(($parentRoot + '\'), [StringComparison]::OrdinalIgnoreCase))
    if ($inApp -or $inDefaultRoot) {
        $safeDir = if ($env:TEMP -and (Test-Path -LiteralPath $env:TEMP -PathType Container)) { $env:TEMP } else { [IO.Path]::GetPathRoot($app) }
        [Environment]::CurrentDirectory = $safeDir
        Set-Location -LiteralPath $safeDir
    }

    # Stop running helper (if any) and remove Startup shortcut first.
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $helperPs1 = Join-Path $app 'close-to-tray.ps1'
    $fallbackPs1 = Join-Path $PSScriptRoot 'close-to-tray.ps1'
    $stopPs1 = if (Test-Path -LiteralPath $helperPs1 -PathType Leaf) { $helperPs1 } elseif (Test-Path -LiteralPath $fallbackPs1 -PathType Leaf) { $fallbackPs1 } else { '' }
    if ($stopPs1 -and (Test-HelperRunning)) {
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $stopPs1 -Stop | Out-Null
        # A helper in the middle of a memory restart stops only after the browser is open again (about two
        # minutes at most); otherwise it stops within a second.
        $deadline = (Get-Date).AddSeconds(130)
        $quietUntil = (Get-Date).AddSeconds(2)
        $announced = $false
        while ((Test-HelperRunning) -and (Get-Date) -lt $deadline) {
            if (-not $announced -and (Get-Date) -gt $quietUntil) {
                Write-Host 'Waiting for Close to Tray Helper to exit (up to 130 s while it finishes a browser restart)...'
                $announced = $true
            }
            Start-Sleep -Milliseconds 150
        }
        if (Test-HelperRunning) {
            Write-Host 'Warning: Close to Tray Helper did not exit within 130 s; it keeps running until it finishes and then exits. Its files are removed now.'
        } else {
            Write-Host 'Stopped running Close to Tray Helper and restored hidden windows.'
        }
    }

    $startupTarget = if ($StartupDir) { Get-FullPath $StartupDir } else { [Environment]::GetFolderPath('Startup') }
    if ($startupTarget) {
        $shortcut = Join-Path $startupTarget 'Close To Tray Helper.lnk'
        if (Test-Path -LiteralPath $shortcut -PathType Leaf) {
            Remove-Item -LiteralPath $shortcut -Force
            Write-Host "Removed Startup shortcut: $shortcut"
        }
    }

    foreach ($plan in $plans) {
        Invoke-UninstallPlan $plan
        Write-Host ("Removed {0}: {1}" -f $plan.Kind, $plan.TargetDir)
    }

    if ($appPlan -and $isDefaultAppRoot) {
        $prefsFile = Join-Path $parentRoot 'prefs.json'
        if (-not $KeepPrefs.IsPresent -and (Test-Path -LiteralPath $prefsFile -PathType Leaf)) {
            Remove-Item -LiteralPath $prefsFile -Force
            Write-Host "Removed preferences: $prefsFile"
        }
        if (Test-Path -LiteralPath $parentRoot -PathType Container) {
            $rem = @(Get-ChildItem -LiteralPath $parentRoot -Force)
            if ($rem.Count -eq 0) {
                Remove-Item -LiteralPath $parentRoot -Force
            }
        }
    }

    if ($plans.Count -eq 0) {
        Write-Host 'No managed Close to Tray Helper installation found.'
    } else {
        Write-Host 'Uninstall complete.'
    }
} catch {
    [Console]::Error.WriteLine("Uninstallation failed: " + $_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit 0
