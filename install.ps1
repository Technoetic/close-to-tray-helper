#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $AppDir = (Join-Path $env:LOCALAPPDATA 'CloseToTrayHelper\app'),
    [ValidateNotNullOrEmpty()][string[]] $SkillsDir,
    [switch] $AppOnly,
    [switch] $SkipSkills,
    [switch] $AllHosts,
    [switch] $Restart
)

$ErrorActionPreference = 'Stop'
$manifestName = '.close-to-tray-bundle.json'

function Get-FullPath([string] $Path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd('\', '/') }
    return $full
}

# Check target and its managed subdirectories/files for reparse points (including
# dangling junctions) without rejecting legitimate user-level symlinks/junctions
# above the StopAt boundary (such as a junctioned .claude dotfiles folder or OneDrive).
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

function Get-StateText($Kind, $Files) {
    return ([ordered]@{ format = "close-to-tray-helper/$Kind/1"; files = $Files } | ConvertTo-Json -Depth 4)
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

# Publish a complete sibling file by rename. An existing copy is replaced only
# when its bytes still match the snapshot taken at preflight.
function Publish-File($Path, $Before, $Source, $After, $Contents, $StopAt) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    $null = Get-CheckedAttributes -Path $parent -Directory -StopAt $StopAt
    $null = [IO.Directory]::CreateDirectory($parent)
    $temp = Join-Path $parent ('.close-to-tray-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        try {
            if ($Source) {
                $inputStream = [IO.File]::OpenRead($Source)
                try { $inputStream.CopyTo($stream) } finally { $inputStream.Dispose() }
            } else {
                $bytes = [Text.Encoding]::UTF8.GetBytes($Contents)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        if ($Source -and (Get-Digest $temp $StopAt) -ne $After) { throw "Source changed: $Source" }
        if ((Get-Digest $Path $StopAt) -ne $Before) { throw "File changed during installation: $Path" }
        if ($Before) {
            [IO.File]::Replace($temp, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temp, $Path)
        }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function New-InstallPlan($Kind, $SourceDir, $TargetDir, $Names) {
    $stopAt = [IO.Path]::GetDirectoryName($TargetDir)
    $null = Get-CheckedAttributes -Path $TargetDir -Directory -StopAt $stopAt
    $manifest = Join-Path $TargetDir $manifestName
    $manifestHash = Get-Digest $manifest $stopAt
    $oldText = $null
    $state = $null
    if ($manifestHash) {
        $oldText = [IO.File]::ReadAllText($manifest)
        $state = ConvertFrom-Json -InputObject $oldText
        if (@($state.psobject.Properties).Count -ne 2 -or $state.format -cne "close-to-tray-helper/$Kind/1" -or
            $null -eq $state.files -or @($state.files.psobject.Properties).Count -lt 1) {
            throw "Unrecognized install manifest: $manifest"
        }
        foreach ($prop in $state.files.psobject.Properties) {
            $vals = @($prop.Value)
            if ($vals.Count -lt 1 -or $vals.Count -gt 2 -or
                @($vals | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[0-9A-Fa-f]{64}$' }).Count) {
                throw "Invalid hashes in install manifest: $manifest"
            }
        }
    }
    $pending = [ordered]@{}
    $final = [ordered]@{}
    $copies = @(foreach ($name in $Names) {
        $source = Join-Path $SourceDir $name
        $target = Join-Path $TargetDir $name
        $after = Get-Digest $source $SourceDir
        if (!$after) { throw "Missing bundle file: $source" }
        $before = Get-Digest $target $stopAt
        $known = @()
        if ($state -and ($state.files.psobject.Properties.Name -contains $name)) {
            $known = @($state.files.$name)
        }
        if ($before -and $before -notin $known) {
            throw "Existing or locally edited file requires manual review: $target"
        }
        $pending[$name] = @($after)
        $final[$name] = @($after)
        if ($before -ne $after) {
            if ($before) {
                if ([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReadOnly) {
                    throw "Read-only file requires manual review: $target"
                }
                $pending[$name] += $before
            }
            [pscustomobject]@{ Path = $target; Before = $before; Source = $source; After = $after }
        }
    })
    $pendingText = Get-StateText $Kind $pending
    $finalText = Get-StateText $Kind $final
    if ($manifestHash -and ($oldText -cne $pendingText -or $oldText -cne $finalText) -and
        ([IO.File]::GetAttributes($manifest) -band [IO.FileAttributes]::ReadOnly)) {
        throw "Read-only install manifest requires manual review: $manifest"
    }
    return [pscustomobject]@{
        Manifest = $manifest; ManifestHash = $manifestHash; Old = $oldText
        Pending = $pendingText; Final = $finalText; Copies = $copies; StopAt = $stopAt
    }
}

function Install-Plan($Plan) {
    # Both the old and new hash are valid while an update is in progress.
    # After interruption, the next run can finish or apply a newer bundle.
    $hash = $Plan.ManifestHash
    if ($Plan.Old -cne $Plan.Pending) {
        Publish-File $Plan.Manifest $hash $null $null $Plan.Pending $Plan.StopAt
        $hash = Get-Digest $Plan.Manifest $Plan.StopAt
    }
    foreach ($copy in $Plan.Copies) {
        Publish-File $copy.Path $copy.Before $copy.Source $copy.After $null $Plan.StopAt
    }
    if ($Plan.Pending -cne $Plan.Final) {
        Publish-File $Plan.Manifest $hash $null $null $Plan.Final $Plan.StopAt
    }
}

function Resolve-DefaultSkillDirs([bool] $IncludeAll) {
    $dirs = @()
    $codexHome = $env:CODEX_HOME
    $codexDefault = Join-Path $env:USERPROFILE '.agents'
    $codexAlt = Join-Path $env:USERPROFILE '.codex'
    if ($IncludeAll -or $codexHome -or (Test-Path -LiteralPath $codexDefault) -or (Test-Path -LiteralPath $codexAlt)) {
        $root = if ($codexHome) { $codexHome } else { $codexDefault }
        $dirs += (Join-Path $root 'skills')
    }

    $claudeHome = $env:CLAUDE_CONFIG_DIR
    $claudeDefault = Join-Path $env:USERPROFILE '.claude'
    if ($IncludeAll -or $claudeHome -or (Test-Path -LiteralPath $claudeDefault)) {
        $root = if ($claudeHome) { $claudeHome } else { $claudeDefault }
        $dirs += (Join-Path $root 'skills')
    }

    $geminiRoot = Join-Path $env:USERPROFILE '.gemini'
    if ($IncludeAll -or (Test-Path -LiteralPath $geminiRoot)) {
        $dirs += (Join-Path $geminiRoot 'config\skills')
    }
    return $dirs
}

$mutex = $null
$locked = $false
try {
    $mutex = [Threading.Mutex]::new($false, 'Local\CloseToTrayHelper.Bundle.Install')
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another bundle installation is already running.' }

    $skipSkillInstall = $AppOnly.IsPresent -or $SkipSkills.IsPresent
    $skillTargets = @()
    if (-not $skipSkillInstall) {
        $resolvedSkillDirs = if ($SkillsDir) { @($SkillsDir) } else { @(Resolve-DefaultSkillDirs -IncludeAll:$AllHosts.IsPresent) }
        $skillTargets = @($resolvedSkillDirs | Where-Object { $_ } | ForEach-Object {
            Join-Path (Get-FullPath $_) 'aside-repl'
        } | Sort-Object -Unique)
    }

    $app = Get-FullPath $AppDir
    if ($app -in $skillTargets) { throw "The application and skill cannot share a directory: $app" }

    $appFiles = @('close-to-tray.ps1', 'close-to-tray-launch.vbs', 'uninstall.ps1', 'uninstall.cmd', 'LICENSE')
    $plans = @(
        New-InstallPlan 'app' $PSScriptRoot $app $appFiles
        foreach ($target in $skillTargets) {
            New-InstallPlan 'aside-repl' (Join-Path $PSScriptRoot '.agents\skills\aside-repl') $target @(
                'SKILL.md', 'scripts\run_repl.py', 'examples\readme-title.js'
            )
        }
    )

    $wasRunning = Test-HelperRunning
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $installedPs1 = Join-Path $app 'close-to-tray.ps1'
    if ($wasRunning -and $Restart.IsPresent) {
        $stopScript = if (Test-Path -LiteralPath $installedPs1 -PathType Leaf) { $installedPs1 } else { Join-Path $PSScriptRoot 'close-to-tray.ps1' }
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $stopScript -Stop | Out-Null
        $deadline = (Get-Date).AddSeconds(5)
        while ((Test-HelperRunning) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 150
        }
    }

    foreach ($plan in $plans) { Install-Plan $plan }

    if ($wasRunning -and $Restart.IsPresent) {
        $vbs = Join-Path $app 'close-to-tray-launch.vbs'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('//B //Nologo "{0}"' -f $vbs)
        Write-Host 'Restarted Close to Tray Helper with the updated files.'
    } elseif ($wasRunning) {
        Write-Host 'Notice: Close to Tray Helper is currently running; restart it (-Stop then relaunch, or run install.ps1 -Restart) to load the updated files.'
    }

    if ($skillTargets.Count -gt 0) {
        foreach ($target in $skillTargets) { Write-Host "Installed skill: $target" }
    } elseif ($skipSkillInstall) {
        Write-Host 'Skipped aside-repl skill installation (-AppOnly / -SkipSkills).'
    } else {
        Write-Host 'No Antigravity, Claude Code, or Codex config folder found; installed tray helper only. Pass -AllHosts or -SkillsDir <path> to install aside-repl skills.'
    }
    Write-Host ('Installed helper: {0}' -f $app)
    Write-Host ('Launch the tray helper: wscript.exe "{0}"' -f (Join-Path $app 'close-to-tray-launch.vbs'))
} catch {
    [Console]::Error.WriteLine("Installation failed: " + $_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit 0
