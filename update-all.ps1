<#
  update-all.ps1 - config-driven GitHub release updater for Windows/x64.

  The registry lives in apps.json (repo, asset, install dir, version probe).
  The installed and latest versions, timestamps and the last working mirror
  are recorded in state.json.

  Per app:
    1. Read the installed version: run version.exe with args and match
       version.regex (capture group 1; two groups are joined with '.'), or
       read the file version of version.file. Probes run through redirected
       handles, so GUI-subsystem exes (noctty) work too.
    2. Probe the latest GitHub release (api.github.com first, then through
       the gh-proxy mirrors) and pick the configured asset (asset, or the
       assetPattern regex). The version comes from the tag; tagRegex selects
       the parts that matter when the tag is not a plain version.
    3. Compare. -Check only reports; otherwise download and install.
    4. Download through the mirror list: reuse the last mirror that worked
       for that app, or benchmark all mirrors and take the fastest.
    5. Verify the asset SHA-256 against the release digest before touching
       any file. No digest => refuse to install.
    6. Install, by mode:
       file - one file to target; zip - entries staged, filtered by
       include/exclude/extract and stripTopLevel, then written; sfx - the
       asset is a self-extractor (PortableGit) run with sfxArgs.
       Staged files whose SHA-256 already matches the target are skipped, so
       only genuinely changed files are written. Changed files are copied to
       backup\<app>\<timestamp>\ first, then overwritten in place (retries
       while a running exe or AV holds the file); a locked executable falls
       back to a single rename-aside for that one file.
       requireNotRunning skips the update (retried on the next run) while the
       program is live: an sfx tree would be left half-written, and a
       portable exe held without FILE_SHARE_DELETE cannot even be renamed.
    7. Re-read the installed version as a smoke test.

    The "self" section of apps.json snapshots the hand-written scripts and
    docs into backup\self\<timestamp>\ before anything else runs, but only
    when their content changed.

  Usage:
    powershell -ExecutionPolicy Bypass -File update-all.ps1
        Update every registered app now.
    ... update-all.ps1 -Check
        Report only (exit 0 = up to date, 1 = update available, 2 = error).
    ... update-all.ps1 -Auto
        Scheduled mode: skip apps already checked today (daily throttle).
    ... update-all.ps1 -Auto -Notify
        Same, plus a balloon tip with the summary.
    ... update-all.ps1 -App chsrc,noctty
        Restrict to the listed ids.
    ... update-all.ps1 -Benchmark
        Measure every mirror instead of reusing the saved one.
    ... update-all.ps1 -Reinstall -App Notepad3
        Reinstall even when installed >= latest (repair an install).
    ... update-all.ps1 -List
        Print the registry and the recorded state, no network.

  IMPORTANT: antivirus heuristics watch for "updater rewrites many files
  in a program directory". Add C:\soft\soft-updater to the trust list of the
  installed AV before relying on the scheduled task.

  NOTE: Keep this file ASCII-only so it parses under every codepage on
  Windows PowerShell 5.1. Mirrors and per-app settings are in apps.json.
#>

param(
    [switch]$Check,
    [switch]$Auto,
    [switch]$Force,
    [switch]$Benchmark,
    [switch]$Reinstall,
    [switch]$Notify,
    [switch]$List,
    [string[]]$App = @()
)

$ErrorActionPreference = "Stop"

$Root        = $PSScriptRoot
$ConfigPath  = Join-Path $Root "apps.json"
$StatePath   = Join-Path $Root "state.json"
$LogPath     = Join-Path $Root "update.log"
$BackupRoot  = Join-Path $Root "backup"
$LockPath    = Join-Path $Root ".lock"
$TmpRoot     = Join-Path $env:TEMP "soft-updater"

# ==================== MIRROR SETTINGS ====================
# The mirror list itself is read from apps.json so it can be edited without
# touching this file. These are the tuning knobs of the download engine,
# identical in behaviour to update-omp.ps1.
$BenchTimeoutSec   = 5
$BenchMinBytes     = 65536
$ConnectTimeoutSec = 5
$MaxDownloadSec    = 3600
$MinSpeedBytes     = 1000000  # 1 MB/s
$MinSpeedWindowSec = 30
$GuardFloorBytes   = 20000
$ProbeTimeoutSec   = 30
$SfxTimeoutSec     = 1800
# ========================================================

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 2MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        Add-Content -Path $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    } catch { }
}

function Write-Step([string]$Message) {
    Write-Host $Message
    Write-Log $Message
}

# Human-readable meaning of the curl exit codes possible on the API query.
function Get-CurlErrorHint([int]$Code) {
    switch ($Code) {
        6   { "hostname could not be resolved (DNS)" }
        7   { "connection failed/refused (proxy down?)" }
        22  { "HTTP error (403 usually = GitHub API rate limit, 60 req/hr per IP)" }
        28  { "timed out" }
        35  { "TLS handshake failed (connection reset en route)" }
        56  { "connection reset" }
        default { "curl error" }
    }
}

function Get-VersionParts([string]$Text) {
    if (-not $Text) { return @() }
    $m = [regex]::Match($Text, '\d+(?:\.\d+)*')
    if (-not $m.Success) { return @() }
    return @($m.Value.Split('.') | ForEach-Object { [int]$_ })
}

# -1 when $A < $B, 0 when equal, 1 when $A > $B. Missing components are 0,
# so "1.4" == "1.4.0".
function Compare-VersionStrings([string]$A, [string]$B) {
    $pa = Get-VersionParts $A
    $pb = Get-VersionParts $B
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $pa.Count) { $x = $pa[$i] }
        if ($i -lt $pb.Count) { $y = $pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.apps) { throw "apps.json has no 'apps' array" }
    return $cfg
}

function Get-State {
    $state = $null
    if (Test-Path $StatePath) {
        try { $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
    }
    if (-not $state) { $state = [pscustomobject]@{} }
    if (-not ($state.PSObject.Properties.Name -contains 'apps')) {
        $state | Add-Member -NotePropertyName 'apps' -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not ($state.PSObject.Properties.Name -contains 'lastMirror')) {
        $state | Add-Member -NotePropertyName 'lastMirror' -NotePropertyValue ''
    }
    return $state
}

function Save-State($State) {
    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $StatePath -Encoding UTF8
}

function Get-AppState($State, [string]$Id) {
    if ($State.apps.PSObject.Properties.Name -contains $Id) { return $State.apps.$Id }
    $s = [pscustomobject]@{
        installed = ''
        latest    = ''
        checkedAt = ''
        updatedAt = ''
        lastError = ''
        lastMirror = ''
    }
    $State.apps | Add-Member -NotePropertyName $Id -NotePropertyValue $s
    return $s
}

# ---------------------------------------------------------------- versions
# Capture group 1 is the version; a probe that needs two groups (git: the
# dotted version plus the ".windows.N" build number) gets them joined with
# '.'. A pattern without capture groups falls back to the whole match -
# silently returning an empty version here would make every app look
# "up to date".
function Get-GroupVersion([System.Text.RegularExpressions.Match]$M) {
    $parts = @()
    for ($i = 1; $i -lt $M.Groups.Count; $i++) {
        if ($M.Groups[$i].Success -and $M.Groups[$i].Value) { $parts += $M.Groups[$i].Value }
    }
    if ($parts.Count -eq 0) { return $M.Value }
    return ($parts -join '.')
}

# Some release binaries (noctty) are GUI-subsystem exes: the call operator
# does not capture their stdout. Run probes with redirected handles so
# console and GUI binaries behave the same, and never let a probe hang a
# scheduled run.
function Invoke-VersionCommand([string]$Exe, [string[]]$ArgList) {
    $outFile = Join-Path $TmpRoot "probe-out.txt"
    $errFile = Join-Path $TmpRoot "probe-err.txt"
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    $p = $null
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $ArgList -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        if (-not $p.WaitForExit($ProbeTimeoutSec * 1000)) { throw "did not exit within $ProbeTimeoutSec s" }
    } catch {
        if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
        throw "Version probe failed: $Exe $($_.Exception.Message)"
    }
    $text = ''
    foreach ($f in @($outFile, $errFile)) { if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw) } }
    return $text
}


function Get-InstalledVersion($App) {
    $v = $App.version
    if ($v.PSObject.Properties.Name -contains 'file') {
        $p = Join-Path $App.installDir $v.file
        if (-not (Test-Path $p)) { return $null }
        $vi = (Get-Item -LiteralPath $p).VersionInfo
        $ver = $vi.ProductVersion
        if (-not $ver) { $ver = $vi.FileVersion }
        if (-not $ver) { throw "No file version for $p" }
        return $ver.Trim()
    }
    $exe = Join-Path $App.installDir $v.exe
    if (-not (Test-Path $exe)) { return $null }
    $argList = @()
    if ($v.PSObject.Properties.Name -contains 'args' -and $v.args) { $argList = @($v.args) }
    $out = Invoke-VersionCommand $exe $argList
    if ($v.PSObject.Properties.Name -contains 'regex' -and $v.regex) {
        $m = [regex]::Match($out, $v.regex)
        if (-not $m.Success) {
            throw "Cannot parse version from '$exe $($argList -join ' ')': $($out.Trim())"
        }
        return (Get-GroupVersion $m)
    }
    return $out.Trim()
}

# ---------------------------------------------------------------- GitHub API

function Get-ApiUrlCandidates([string]$Repo, $Cfg, $State) {
    $apiUrl = "https://api.github.com/repos/$Repo/releases/latest"
    $urls = @($apiUrl)
    $mirrors = @($Cfg.mirrors)
    $urlStyle = @()
    if ($Cfg.PSObject.Properties.Name -contains 'urlStyleMirrors') { $urlStyle = @($Cfg.urlStyleMirrors) }

    $order = @()
    $last = Get-LastMirror $State ''
    if ($last) { $order += $last }
    foreach ($m in $mirrors) { if ($order -notcontains $m) { $order += $m } }

    foreach ($m in $order) {
        if ($urlStyle -contains $m) {
            $urls += $m + $apiUrl
        } elseif ($m -cmatch 'github\.com$') {
            $urls += ($m -creplace 'github\.com$', 'api.github.com') + "/repos/$Repo/releases/latest"
        } else {
            $urls += $m + "/repos/$Repo/releases/latest"
        }
    }
    return $urls
}

function Get-LatestRelease($App, $Cfg, $State) {
    $repo = $App.repo
    $errors = @()
    $headers = @()
    if ($env:GITHUB_TOKEN) { $headers = @('-H', "Authorization: Bearer $env:GITHUB_TOKEN") }

    foreach ($url in (Get-ApiUrlCandidates $repo $Cfg $State)) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $json = (curl.exe -sS --fail --connect-timeout 8 --max-time 25 @headers $url 2>$null | Out-String)
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
        if ($code -ne 0) {
            $errors += "$url -> curl exit $code ($(Get-CurlErrorHint $code))"
            continue
        }
        $release = $null
        try { $release = $json | ConvertFrom-Json } catch { }
        if (-not $release -or -not $release.tag_name) {
            $errors += "$url -> answered, but not a release JSON (error page?)"
            continue
        }

        $asset = $null
        if ($App.PSObject.Properties.Name -contains 'asset' -and $App.asset) {
            $asset = @($release.assets | Where-Object { $_.name -eq $App.asset -and $_.state -eq 'uploaded' })[0]
        }
        if (-not $asset -and $App.PSObject.Properties.Name -contains 'assetPattern' -and $App.assetPattern) {
            $asset = @($release.assets | Where-Object { $_.name -match $App.assetPattern -and $_.state -eq 'uploaded' })[0]
        }
        if (-not $asset) {
            throw "Asset not found in release $($release.tag_name) of $repo (wanted '$($App.asset)$($App.assetPattern)')"
        }
        if ($asset.digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
            throw "No SHA-256 digest for $($asset.name) in release $($release.tag_name); refusing to update without verification"
        }
        # Tags are usually "v1.2.3"; some carry extra structure that has to
        # survive into the comparison (git: v2.56.0.windows.2 -> 2.56.0.2),
        # which is what the optional tagRegex is for.
        $tagPattern = '\d+(?:\.\d+)*'
        if ($App.PSObject.Properties.Name -contains 'tagRegex' -and $App.tagRegex) { $tagPattern = $App.tagRegex }
        $tagVersion = [regex]::Match($release.tag_name, $tagPattern)
        if (-not $tagVersion.Success) { throw "Cannot parse a version from tag '$($release.tag_name)' (pattern '$tagPattern')" }
        $latest = Get-GroupVersion $tagVersion
        if (-not $latest) { throw "Tag '$($release.tag_name)' matched '$tagPattern' but produced no version" }

        return [pscustomobject]@{
            Tag         = $release.tag_name
            Version     = $latest
            AssetName   = $asset.name
            ExpectedSha = ($asset.digest -replace '^sha256:', '').ToUpper()
            GithubUrl   = $asset.browser_download_url
            Size        = [long]$asset.size
        }
    }
    throw ("Failed to query the latest release of ${repo} via all $($errors.Count) endpoint(s):`n" + ($errors -join "`n"))
}

# ---------------------------------------------------------------- mirrors

function Get-MirrorUrl([string]$Prefix, [string]$GithubUrl, [string]$GithubPath, $Cfg) {
    $urlStyle = @()
    if ($Cfg.PSObject.Properties.Name -contains 'urlStyleMirrors') { $urlStyle = @($Cfg.urlStyleMirrors) }
    if ($urlStyle -contains $Prefix) { return $Prefix + $GithubUrl }
    return $Prefix + $GithubPath
}

function Get-LastMirror($State, [string]$AppId) {
    $candidates = @()
    if ($AppId -and $State.apps.PSObject.Properties.Name -contains $AppId) {
        $candidates += [string]$State.apps.$AppId.lastMirror
    }
    $candidates += [string]$State.lastMirror
    foreach ($c in $candidates) {
        if ($c) { return $c }
    }
    return ''
}

function Get-MirrorOrder($State, [string]$AppId, $Cfg) {
    $order = @()
    $last = Get-LastMirror $State $AppId
    if ($last) { $order += $last }
    foreach ($m in @($Cfg.mirrors)) { if ($order -notcontains $m) { $order += $m } }
    return $order
}

# Pull up to $BenchTimeoutSec seconds of the real asset and report the
# average throughput over the transfer only (DNS/connect/TLS excluded).
function Measure-MirrorSpeed([string]$Url, [string]$BenchFile) {
    Remove-Item $BenchFile -Force -ErrorAction SilentlyContinue
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $stat = (curl.exe -s -L --fail --connect-timeout $ConnectTimeoutSec --max-time $BenchTimeoutSec -o $BenchFile -w "%{http_code} %{size_download} %{time_total} %{time_connect} %{time_appconnect}" $Url 2>$null | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $wall = $sw.Elapsed.TotalSeconds
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $http = 0; $bytes = 0L; $total = 0.0; $setup = 0.0
    if ($stat -match "(\d{3})\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)") {
        $http  = [int]$Matches[1]
        $bytes = [long]$Matches[2]
        $total = [double]::Parse($Matches[3], $ci)
        $setup = [double]::Parse($Matches[4], $ci)
        $tls   = [double]::Parse($Matches[5], $ci)
        if ($tls -gt $setup) { $setup = $tls }
    }
    if ($bytes -eq 0 -and (Test-Path $BenchFile)) { $bytes = (Get-Item $BenchFile).Length }
    $xfer = $total - $setup
    if ($xfer -le 0) { $xfer = $wall }
    $speed = 0.0
    if ($xfer -gt 0) { $speed = [double]$bytes / $xfer }
    return [pscustomobject]@{ Bytes = $bytes; Speed = $speed; Curl = $code; Http = $http }
}

function Invoke-MirrorDownload([string]$Prefix, [string]$GithubUrl, [string]$GithubPath, [string]$OutFile, [long]$ExpectedSize, [int]$GuardBytes, $Cfg, [ref]$Why) {
    $u = Get-MirrorUrl $Prefix $GithubUrl $GithubPath $Cfg
    $curlArgs = @('-L', '--fail', '--show-error', '--connect-timeout', "$ConnectTimeoutSec", '--max-time', "$MaxDownloadSec", '-o', $OutFile)
    if ($GuardBytes -gt 0) { $curlArgs += @('--speed-limit', "$GuardBytes", '--speed-time', "$MinSpeedWindowSec") }
    Write-Step "[download] $u (floor $GuardBytes B/s, ceiling $MaxDownloadSec s)"
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    curl.exe @curlArgs $u
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        if ($code -eq 28) { $Why.Value = "average speed below $GuardBytes B/s after $MinSpeedWindowSec s" }
        else { $Why.Value = "curl exit code $code" }
        return $false
    }
    $got = 0
    if (Test-Path $OutFile) { $got = (Get-Item $OutFile).Length }
    if ($ExpectedSize -gt 0 -and $got -ne $ExpectedSize) {
        Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        $Why.Value = "downloaded $got byte(s), expected $ExpectedSize"
        return $false
    }
    return $true
}

# Download $Rel.AssetName into $OutFile, reusing the mirror that worked for
# this app last time; on failure benchmark every mirror and walk the ranking.
function Save-Asset($App, $Rel, $OutFile, $Cfg, $State) {
    $GithubUrl  = $Rel.GithubUrl
    $GithubPath = $GithubUrl.Substring('https://github.com'.Length)
    $bench = Join-Path $TmpRoot "bench-$($App.id).bin"
    $used = $null
    $failures = @()

    $last = Get-LastMirror $State $App.id
    if ($last -and -not $Benchmark) {
        Write-Step "[mirror] $($App.id): reusing last successful mirror: $last"
        $why = $null
        if (Invoke-MirrorDownload $last $GithubUrl $GithubPath $OutFile $Rel.Size $MinSpeedBytes $Cfg ([ref]$why)) {
            $used = $last
        } else {
            Write-Step "  [retry] $last failed ($why); measuring all mirrors instead"
            $failures += "$last ($why)"
        }
    }

    if (-not $used) {
        $mirrors = @(Get-MirrorOrder $State $App.id $Cfg)
        Write-Step "[bench] $($App.id): measuring $($mirrors.Count) mirror(s), max $BenchTimeoutSec s each ..."
        $ranked = @()
        foreach ($m in $mirrors) {
            $r = Measure-MirrorSpeed (Get-MirrorUrl $m $GithubUrl $GithubPath $Cfg) $bench
            if ($r.Bytes -lt $BenchMinBytes) {
                Write-Step ("  [dead] {0} (http {1}, {2} byte(s), curl {3})" -f $m, $r.Http, $r.Bytes, $r.Curl)
                continue
            }
            $ranked += [pscustomobject]@{ Prefix = $m; Speed = $r.Speed }
            Write-Step ("  [{0,7:N0} KB/s] {1}" -f ($r.Speed / 1KB), $m)
            if ($r.Speed -ge $MinSpeedBytes) {
                Write-Step "[bench] $m already sustains 1 MB/s or more; stopping the sweep"
                break
            }
        }
        Remove-Item $bench -Force -ErrorAction SilentlyContinue
        if ($ranked.Count -eq 0) {
            $extra = ''
            if ($failures.Count) { $extra = "; direct attempt already failed: $($failures -join '; ')" }
            throw "No mirror transferred data (all $($mirrors.Count) measured mirror(s) stayed under $BenchMinBytes byte(s) in $BenchTimeoutSec s$extra)"
        }
        $ranked = @($ranked | Sort-Object -Descending Speed)
        Write-Step ("[bench] fastest: {0} ({1:N0} KB/s)" -f $ranked[0].Prefix, ($ranked[0].Speed / 1KB))
        foreach ($c in $ranked) {
            $guard = $MinSpeedBytes
            if ($c.Speed -lt $MinSpeedBytes) { $guard = [int][math]::Max($GuardFloorBytes, $c.Speed * 0.5) }
            $why = $null
            if (Invoke-MirrorDownload $c.Prefix $GithubUrl $GithubPath $OutFile $Rel.Size $guard $Cfg ([ref]$why)) {
                $used = $c.Prefix
                break
            }
            Write-Step "  [retry] mirror $($c.Prefix) failed ($why); trying the next one in the ranking"
            $failures += "$($c.Prefix) ($why)"
        }
    }
    Remove-Item $bench -Force -ErrorAction SilentlyContinue
    if (-not $used) {
        throw "Download failed on all $($failures.Count) mirror(s): $($failures -join '; ')"
    }
    return $used
}

# SHA-256 of a freshly written file. Opens with ReadWrite|Delete sharing and
# retries briefly: Defender keeps large downloads locked for a moment.
function Get-FileSha256([string]$Path) {
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $lastErr = ''
    for ($try = 1; $try -le 20; $try++) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $bytes = $sha.ComputeHash($fs)
            $fs.Dispose()
            return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToUpper()
        } catch {
            $lastErr = $_.Exception.Message
            if ($fs) { try { $fs.Dispose() } catch { } }
            if ($try -lt 20) { Start-Sleep -Seconds 2 }
        }
    }
    throw "Cannot hash $Path after 20 attempts (40 s): $lastErr"
}

# ---------------------------------------------------------------- install

# A multi-file install (sfx) and a portable build that holds its own exe
# without FILE_SHARE_DELETE (Netcatty) cannot be written while the program
# runs - the file cannot even be renamed. Rather than killing the user's
# app, such updates are skipped and retried on the next run. Only processes
# actually running out of this install dir count, so an unrelated bash.exe
# (msys2, git-bash elsewhere) does not block the update; a process whose
# path cannot be read counts as a hit for the same reason.
function Get-AppBusyProcesses($App) {
    if (-not ($App.PSObject.Properties.Name -contains 'requireNotRunning')) { return @() }
    $busy = @()
    foreach ($name in @($App.requireNotRunning)) {
        foreach ($p in @(Get-Process -Name ([string]$name) -ErrorAction SilentlyContinue)) {
            $exePath = ''
            try { $exePath = [string]$p.Path } catch { }
            if ($exePath -and -not $exePath.StartsWith($App.installDir, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $busy += "$($p.ProcessName) pid $($p.Id)"
        }
    }
    return $busy
}

function Assert-SafeRelativePath([string]$Path) {
    if (-not $Path) { throw "Empty path in zip entry" }
    if ([System.IO.Path]::IsPathRooted($Path)) { throw "Absolute path in zip entry: $Path" }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { throw "Path traversal in zip entry: $Path" }
}

function Expand-ZipAsset([string]$ZipPath, $App, [string]$Stage) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    $written = @()
    try {
        $extract = @()
        if ($App.PSObject.Properties.Name -contains 'extract') { $extract = @($App.extract) }
        $include = @()
        if ($App.PSObject.Properties.Name -contains 'include') { $include = @($App.include) }
        $exclude = @()
        if ($App.PSObject.Properties.Name -contains 'exclude') { $exclude = @($App.exclude) }
        $stripTopLevel = $false
        if ($App.PSObject.Properties.Name -contains 'stripTopLevel') { $stripTopLevel = [bool]$App.stripTopLevel }

        if ($extract.Count -gt 0) {
            foreach ($rule in $extract) {
                $hits = @($archive.Entries | Where-Object {
                    $n = $_.FullName.Replace('\', '/')
                    ($n -like $rule.from) -and -not $n.EndsWith('/')
                })
                if ($hits.Count -eq 0) { throw "Zip has no entry matching '$($rule.from)'" }
                foreach ($e in $hits) {
                    $to = ''
                    if ($rule.PSObject.Properties.Name -contains 'to') { $to = [string]$rule.to }
                    if (-not $to) { $to = Split-Path $e.FullName -Leaf }
                    if ($to.EndsWith('/') -or $to.EndsWith('\')) { $to = $to + (Split-Path $e.FullName -Leaf) }
                    Assert-SafeRelativePath $to
                    $dest = Join-Path $Stage $to
                    $parent = Split-Path $dest -Parent
                    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                    if ($written -notcontains $to) { $written += $to }
                }
            }
        } else {
            foreach ($e in $archive.Entries) {
                # Windows-built zips (Pi-Bolt) separate entries with '\';
                # normalize so include/exclude and the top-level strip work
                # for both conventions.
                $name = $e.FullName.Replace('\', '/')
                if ($name.EndsWith('/')) { continue }
                if ($stripTopLevel) {
                    $slash = $name.IndexOf('/')
                    if ($slash -ge 0) { $name = $name.Substring($slash + 1) }
                    if (-not $name) { continue }
                }
                $skip = $false
                foreach ($p in $exclude) { if ($name -like $p) { $skip = $true; break } }
                if ($skip) { continue }
                if ($include.Count -gt 0) {
                    $hit = $false
                    foreach ($p in $include) { if ($name -like $p) { $hit = $true; break } }
                    if (-not $hit) { continue }
                }
                Assert-SafeRelativePath $name
                $dest = Join-Path $Stage $name
                $parent = Split-Path $dest -Parent
                if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                if ($written -notcontains $name) { $written += $name }
            }
        }
    } finally {
        $archive.Dispose()
    }
    if ($written.Count -eq 0) { throw "Zip $ZipPath contained no files to install (check extract/include)" }
    return $written
}

# Replace one file. A direct overwrite is tried first: it is the pattern
# every normal installer shows and keeps AV heuristics quiet. Only when the
# destination is locked (running exe) does the file get renamed aside once,
# and that aside copy is deleted right after the move.
function Set-FileContent([string]$Source, [string]$Destination) {
    $parent = Split-Path $Destination -Parent
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $lastErr = ''
    for ($try = 1; $try -le 5; $try++) {
        try {
            [System.IO.File]::Copy($Source, $Destination, $true)
            return
        } catch {
            $lastErr = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    }

    # Locked destination: rename just this one file aside, move the new one
    # in, then delete the aside copy (a running exe's image cannot be
    # deleted, it is left for the next run to collect).
    $leaf = Split-Path $Destination -Leaf
    $aside = Join-Path $parent ("$leaf.supd-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    try {
        Rename-Item -LiteralPath $Destination -NewName (Split-Path $aside -Leaf) -Force
    } catch {
        throw "Cannot replace $Destination (still locked after 5 attempts): $lastErr; rename aside also failed: $($_.Exception.Message)"
    }
    Move-Item -LiteralPath $Source -Destination $Destination -Force
    Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue
}

# Files whose staged copy is byte-identical to the installed copy are left
# alone, so a version bump only writes what actually changed.
function Test-SameContent([string]$A, [string]$B) {
    try {
        $ia = Get-Item -LiteralPath $A
        $ib = Get-Item -LiteralPath $B
        if ($ia.Length -ne $ib.Length) { return $false }
        return ((Get-FileSha256 $A) -eq (Get-FileSha256 $B))
    } catch {
        return $false
    }
}

function Install-Asset($App, [string]$Download, $Rel) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path (Join-Path $BackupRoot $App.id) $stamp
    $changed = 0

    # Aside copies left by an earlier run become deletable once the process
    # that held them exits. Only this tool's own naming pattern is touched.
    Get-ChildItem -LiteralPath $App.installDir -Recurse -Force -File -Filter '*.supd-*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    if ($App.mode -eq 'file') {
        $target = Join-Path $App.installDir $App.target
        if (Test-Path -LiteralPath $target) {
            if (Test-SameContent $Download $target) {
                Write-Step "[skip] $($App.id): $($App.target) is already the new content"
                return
            }
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Copy-Item -LiteralPath $target -Destination (Join-Path $backupDir (Split-Path $target -Leaf)) -Force
        }
        Set-FileContent $Download $target
        $changed++
    } elseif ($App.mode -eq 'zip') {
        $stage = Join-Path $TmpRoot "stage-$($App.id)-$stamp"
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        try {
            $files = @(Expand-ZipAsset $Download $App $stage)
            foreach ($relPath in $files) {
                $src = Join-Path $stage $relPath
                $dest = Join-Path $App.installDir $relPath
                if ((Test-Path -LiteralPath $dest) -and (Test-SameContent $src $dest)) { continue }
                if (Test-Path -LiteralPath $dest) {
                    $bak = Join-Path $backupDir $relPath
                    $bakParent = Split-Path $bak -Parent
                    if ($bakParent) { New-Item -ItemType Directory -Force -Path $bakParent | Out-Null }
                    Copy-Item -LiteralPath $dest -Destination $bak -Force
                }
                Set-FileContent $src $dest
                $changed++
            }
        } finally {
            Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($changed -eq 0) {
            Write-Step "[skip] $($App.id): every file already matches the release"
        }
    } elseif ($App.mode -eq 'sfx') {
        # Self-extracting archive (PortableGit ships a 7z SFX). The vendor's
        # own extractor does the writing, so there is no per-file backup
        # here; the guard is requireNotRunning, checked before the download.
        $sfxArgs = @('-y', "-o$($App.installDir)")
        if ($App.PSObject.Properties.Name -contains 'sfxArgs' -and $App.sfxArgs) {
            $sfxArgs = @($App.sfxArgs | ForEach-Object { [string]$_ -replace '\{installDir\}', $App.installDir })
        }
        Write-Step "[install] $($App.id): running the self-extractor ($($sfxArgs -join ' '))"
        $p = $null
        try {
            $p = Start-Process -FilePath $Download -ArgumentList $sfxArgs -PassThru -WindowStyle Hidden
            if (-not $p.WaitForExit($SfxTimeoutSec * 1000)) { throw "did not finish within $SfxTimeoutSec s" }
        } catch {
            if ($p -and -not $p.HasExited) { try { $p.Kill() } catch { } }
            throw "Self-extractor for $($App.id) failed: $($_.Exception.Message)"
        }
        if ($p.ExitCode -ne 0) { throw "Self-extractor for $($App.id) exited with code $($p.ExitCode)" }
        $changed++
    } else {
        throw "Unknown mode '$($App.mode)' for $($App.id) (expected 'file', 'zip' or 'sfx')"
    }

    if (-not (Test-Path -LiteralPath $backupDir)) { return }

    # Keep the two most recent backups per app; only directories this tool
    # created are ever touched.
    $appBackups = @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot $App.id) -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($appBackups.Count -gt 2) {
        $appBackups | Select-Object -Skip 2 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Show-Notification([string]$Title, [string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.BalloonTipTitle = $Title
        $n.BalloonTipText = $Text
        $n.Visible = $true
        $n.ShowBalloonTip(10000)
        Start-Sleep -Seconds 10
        $n.Dispose()
    } catch { }
}

# The tool's own scripts and docs are hand-edited, so they get the same
# treatment as an installed app: a snapshot before anything else runs, and
# only when the content actually changed.
function Get-SnapshotRelativePath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace ':', '')
}

function Save-SelfSnapshot($Cfg) {
    if (-not ($Cfg.PSObject.Properties.Name -contains 'self')) { return }
    $self = $Cfg.self
    $keep = 5
    if ($self.PSObject.Properties.Name -contains 'keep' -and $self.keep) { $keep = [int]$self.keep }
    $files = @($self.files | Where-Object { $_ } | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $Root $_ }
    })
    $missing = @($files | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count -gt 0) { Write-Step "[self] not found, skipped: $($missing -join ', ')" }
    $files = @($files | Where-Object { Test-Path -LiteralPath $_ })
    if ($files.Count -eq 0) { return }

    $selfRoot = Join-Path $BackupRoot 'self'
    $prev = @(Get-ChildItem -LiteralPath $selfRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($prev.Count -gt 0) {
        $same = $true
        foreach ($f in $files) {
            $cand = Join-Path $prev[0].FullName (Get-SnapshotRelativePath $f)
            if (-not (Test-Path -LiteralPath $cand) -or -not (Test-SameContent $f $cand)) { $same = $false; break }
        }
        if ($same) {
            Write-Step "[self] scripts and docs unchanged since $($prev[0].Name) ($($files.Count) file(s))"
            return
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $selfRoot $stamp
    foreach ($f in $files) {
        $target = Join-Path $dest (Get-SnapshotRelativePath $f)
        $parent = Split-Path $target -Parent
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $f -Destination $target -Force
    }
    Write-Step "[self] snapshot of $($files.Count) file(s) -> $dest"

    $all = @(Get-ChildItem -LiteralPath $selfRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($all.Count -gt $keep) {
        $all | Select-Object -Skip $keep | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- main

if (-not (Test-Path $TmpRoot)) { New-Item -ItemType Directory -Force -Path $TmpRoot | Out-Null }

# One instance at a time: a manual run must not fight the scheduled one.
$lock = $null
try {
    $lock = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    Write-Host "[skip] another soft-updater instance is running ($LockPath)"
    exit 0
}

try {
    $cfg = Get-Config
    $state = Get-State
    $allApps = @($cfg.apps)

    if (-not $List) { Save-SelfSnapshot $cfg }

    if ($List) {
        $rows = @()
        foreach ($a in $allApps) {
            $st = $null
            if ($state.apps.PSObject.Properties.Name -contains $a.id) { $st = $state.apps.($a.id) }
            $rows += [pscustomobject]@{
                App        = $a.id
                Repo       = $a.repo
                Mode       = $a.mode
                InstallDir = $a.installDir
                Installed  = if ($st) { $st.installed } else { '' }
                Latest     = if ($st) { $st.latest } else { '' }
                Checked    = if ($st) { $st.checkedAt } else { '' }
            }
        }
        if ($cfg.PSObject.Properties.Name -contains 'self') {
            $snaps = @(Get-ChildItem -LiteralPath (Join-Path $BackupRoot 'self') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            $rows += [pscustomobject]@{
                App        = 'self'
                Repo       = '(local scripts and docs)'
                Mode       = 'snapshot'
                InstallDir = (Join-Path $BackupRoot 'self')
                Installed  = "$($snaps.Count) snapshot(s)"
                Latest     = ''
                Checked    = if ($snaps.Count -gt 0) { $snaps[0].Name } else { '' }
            }
        }
        $rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
        exit 0
    }

    $selected = @()
    if ($App.Count -gt 0) {
        $ids = @()
        foreach ($raw in $App) { foreach ($piece in ($raw -split ',')) { if ($piece.Trim()) { $ids += $piece.Trim() } } }
        foreach ($id in $ids) {
            $match = @($allApps | Where-Object { $_.id -eq $id })
            if ($match.Count -eq 0) { throw "Unknown app id '$id' (see -List)" }
            $selected += $match
        }
    } else {
        $selected = $allApps
    }

    $today = (Get-Date).Date
    $results = @()
    $anyError = $false
    $anyUpdate = $false

    foreach ($a in $selected) {
        $st = Get-AppState $state $a.id
        $status = ''
        $note = ''
        try {
            $installed = Get-InstalledVersion $a
            if (-not $installed) {
                $installed = '0.0.0'
                Write-Step "[info] $($a.id): not installed at $($a.installDir); installing fresh"
            }
            $st.installed = $installed

            if ($Auto -and -not $Force -and $st.checkedAt) {
                $checked = [datetime]$st.checkedAt
                if ($checked.Date -eq $today) {
                    Write-Step "[skip] $($a.id): already checked today ($($checked.ToString('yyyy-MM-dd HH:mm'))). Use -Force to check again."
                    $results += [pscustomobject]@{ App = $a.id; Installed = $installed; Latest = $st.latest; Status = 'skipped (checked today)'; Note = '' }
                    continue
                }
            }

            $rel = Get-LatestRelease $a $cfg $state
            $st.latest = $rel.Version
            $st.checkedAt = (Get-Date).ToString('o')
            $st.lastError = ''
            Write-Step "[info] $($a.id): installed=$installed latest=$($rel.Version) asset=$($rel.AssetName)"

            $cmp = Compare-VersionStrings $installed $rel.Version
            if ($cmp -ge 0 -and -not $Reinstall) {
                $status = 'up to date'
                Write-Step "[check] $($a.id): up to date ($installed)."
            } elseif ($Check) {
                $status = 'update available'
                $anyUpdate = $true
                Write-Step "[check] $($a.id): update available: $installed -> $($rel.Version)"
            } else {
                $from = $installed
                $busy = @(Get-AppBusyProcesses $a)
                if ($busy.Count -gt 0) {
                    $status = 'skipped (running)'
                    $note = "in use: $($busy -join ', ')"
                    Write-Step "[skip] $($a.id): $note; retried on the next run"
                } else {
                    Write-Step "[update] $($a.id): $from -> $($rel.Version)"

                    $dl = Join-Path $TmpRoot "$($a.id)-$($rel.AssetName)"
                    $used = Save-Asset $a $rel $dl $cfg $state

                    $actual = Get-FileSha256 $dl
                    if ($actual -ne $rel.ExpectedSha) {
                        Remove-Item $dl -Force -ErrorAction SilentlyContinue
                        throw "SHA-256 mismatch for $($a.id)! actual=$actual expected=$($rel.ExpectedSha)"
                    }
                    Write-Step "[verify] $($a.id): SHA-256 OK ($actual)"

                    Install-Asset $a $dl $rel
                    Remove-Item $dl -Force -ErrorAction SilentlyContinue

                    $st.lastMirror = $used
                    $state.lastMirror = $used
                    $st.updatedAt = (Get-Date).ToString('o')

                    $newInstalled = Get-InstalledVersion $a
                    if (-not $newInstalled) { throw "Smoke test failed: $($a.id) not found after install" }
                    $st.installed = $newInstalled
                    if ((Compare-VersionStrings $newInstalled $rel.Version) -ne 0) {
                        throw "Smoke test failed: got $newInstalled, expected $($rel.Version) (backup: $BackupRoot\$($a.id))"
                    }
                    $status = 'updated'
                    Write-Step "[done] $($a.id): updated to $newInstalled (backup: $BackupRoot\$($a.id))"
                }
            }
        } catch {
            $anyError = $true
            $status = 'error'
            $note = $_.Exception.Message
            $st.lastError = $note
            Write-Step "[error] $($a.id): $note"
        }
        $results += [pscustomobject]@{ App = $a.id; Installed = $st.installed; Latest = $st.latest; Status = $status; Note = $note }
        Save-State $state
    }

    Save-State $state

    Write-Host ''
    $results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

    if ($Notify) {
        $updated = @($results | Where-Object { $_.Status -eq 'updated' })
        $failed = @($results | Where-Object { $_.Status -eq 'error' })
        if ($updated.Count -gt 0 -or $failed.Count -gt 0) {
            $text = "$($updated.Count) updated, $($failed.Count) failed."
            if ($updated.Count -gt 0) { $text += " " + (($updated | ForEach-Object { "$($_.App) $($_.Latest)" }) -join ', ') }
            Show-Notification "soft-updater" $text
        }
    }

    if ($anyError) { exit 2 }
    if ($Check -and $anyUpdate) { exit 1 }
    exit 0
} finally {
    if ($lock) { $lock.Dispose() }
}
