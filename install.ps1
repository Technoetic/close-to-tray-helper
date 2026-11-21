#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string] $AppDir = (Join-Path $env:LOCALAPPDATA 'CloseToTrayHelper\app'),
    [ValidateNotNullOrEmpty()][string[]] $SkillsDir
)

$ErrorActionPreference = 'Stop'
$manifestName = '.close-to-tray-bundle.json'

function Get-FullPath([string] $Path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd('\', '/') }
    return $full
}

# Check each ancestor before following the path, including dangling junctions.
function Get-CheckedAttributes([string] $Path, [switch] $Directory) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { $null = Get-CheckedAttributes $parent -Directory }
    try { $attributes = [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] { return }
    catch [IO.DirectoryNotFoundException] { return }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Linked path requires manual review: $Path"
    }
    if ([bool]($attributes -band [IO.FileAttributes]::Directory) -ne $Directory.IsPresent) {
        throw "Unexpected file or directory: $Path"
    }
    return $attributes
}

function Get-Digest([string] $Path) {
    if ($null -ne (Get-CheckedAttributes $Path)) {
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    }
}

function Get-StateText($Kind, $Files) {
    return ([ordered]@{ format = "close-to-tray-helper/$Kind/1"; files = $Files } | ConvertTo-Json -Depth 4)
}

# Publish a complete sibling file by rename. An existing copy is replaced only
# when its bytes still match the snapshot taken at preflight.
function Publish-File($Path, $Before, $Source, $After, $Contents) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    $null = Get-CheckedAttributes $parent -Directory
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
        if ($Source -and (Get-Digest $temp) -ne $After) { throw "Source changed: $Source" }
        if ((Get-Digest $Path) -ne $Before) { throw "File changed during installation: $Path" }
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
    $manifest = Join-Path $TargetDir $manifestName
    $manifestHash = Get-Digest $manifest
    $oldText = $null
    $state = $null
    if ($manifestHash) {
        $oldText = [IO.File]::ReadAllText($manifest)
        $state = ConvertFrom-Json -InputObject $oldText
        if (@($state.psobject.Properties).Count -ne 2 -or $state.format -cne "close-to-tray-helper/$Kind/1" -or
            $null -eq $state.files -or @($state.files.psobject.Properties).Count -ne $Names.Count) {
            throw "Unrecognized install manifest: $manifest"
        }
    }
    $pending = [ordered]@{}
    $final = [ordered]@{}
    $copies = @(foreach ($name in $Names) {
        $source = Join-Path $SourceDir $name
        $target = Join-Path $TargetDir $name
        $after = Get-Digest $source
        if (!$after) { throw "Missing bundle file: $source" }
        $before = Get-Digest $target
        $known = @()
        if ($state) {
            $known = @($state.files.$name)
            if ($known.Count -lt 1 -or $known.Count -gt 2 -or
                @($known | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[0-9A-Fa-f]{64}$' }).Count) {
                throw "Invalid hashes in install manifest: $manifest"
            }
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
        Pending = $pendingText; Final = $finalText; Copies = $copies
    }
}

function Install-Plan($Plan) {
    # Both the old and new hash are valid while an update is in progress.
    # After interruption, the next run can finish or apply a newer bundle.
    $hash = $Plan.ManifestHash
    if ($Plan.Old -cne $Plan.Pending) {
        Publish-File $Plan.Manifest $hash $null $null $Plan.Pending
        $hash = Get-Digest $Plan.Manifest
    }
    foreach ($copy in $Plan.Copies) {
        Publish-File $copy.Path $copy.Before $copy.Source $copy.After $null
    }
    if ($Plan.Pending -cne $Plan.Final) {
        Publish-File $Plan.Manifest $hash $null $null $Plan.Final
    }
}

$mutex = $null
$locked = $false
try {
    $mutex = [Threading.Mutex]::new($false, 'Local\CloseToTrayHelper.Bundle.Install')
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Another bundle installation is already running.' }
    if (!$SkillsDir) {
        $codex = $env:CODEX_HOME
        if (!$codex) { $codex = Join-Path $env:USERPROFILE '.agents' }
        $claude = $env:CLAUDE_CONFIG_DIR
        if (!$claude) { $claude = Join-Path $env:USERPROFILE '.claude' }
        $SkillsDir = @(
            (Join-Path $codex 'skills')
            (Join-Path $claude 'skills')
            (Join-Path $env:USERPROFILE '.gemini\config\skills')
        )
    }
    $app = Get-FullPath $AppDir
    $skillTargets = @($SkillsDir | ForEach-Object {
        Join-Path (Get-FullPath $_) 'aside-repl'
    } | Sort-Object -Unique)
    if ($app -in $skillTargets) { throw "The application and skill cannot share a directory: $app" }

    $plans = @(
        New-InstallPlan 'app' $PSScriptRoot $app @('close-to-tray.ps1', 'close-to-tray-launch.vbs', 'LICENSE')
        foreach ($target in $skillTargets) {
            New-InstallPlan 'aside-repl' (Join-Path $PSScriptRoot '.agents\skills\aside-repl') $target @(
                'SKILL.md', 'scripts\run_repl.py', 'examples\readme-title.js'
            )
        }
    )
    foreach ($plan in $plans) { Install-Plan $plan }
    foreach ($target in $skillTargets) { Write-Host "Installed skill: $target" }
    Write-Host ('Launch the tray helper: wscript.exe "{0}"' -f (Join-Path $app 'close-to-tray-launch.vbs'))
} catch {
    [Console]::Error.WriteLine("Installation failed: " + $_.Exception.Message)
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
exit 0
