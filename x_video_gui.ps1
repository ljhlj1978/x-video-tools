<#
  X 视频批量下载器（窗口版 v2 · 系统托盘常驻）

  双击「X视频批量下载.bat」打开窗口：
    · 一次粘贴 / 导入多条推文链接，逐条排队下载
    · 断点续传：中途点「停止」或关掉窗口，半成品文件会保留；
      下次打开窗口会自动恢复未完成任务，从已下载字节接着下
    · 列表逐项显示状态与已下载字节、总进度条、运行日志
    · 点右上角 × 不退出：窗口收进系统托盘，下载在后台继续；
      双击托盘图标恢复窗口，右键「退出程序」或窗口里的「退出程序」才真正结束

  断点续传怎么做到：
    1) 先用 yt-dlp -g 解析出真实 MP4 直链（受限推文自动走公开解析接口）
    2) 用「推文ID + 序号 + 直链文件名」生成固定输出文件名，不需要重新解析元数据
    3) curl -L -C - 直接写目标文件；中断后文件保留，下次从文件大小处发 Range 请求
    4) 输出目录里的 .xdl_state.json 记录已完成项，重开窗口可恢复队列、跳过已完成
    仅单文件 MP4 直链支持字节续传；分片流 / 音视频分离流自动改走 yt-dlp 原生下载
    （其 .part 文件也支持续传，但不能跨会话按字节恢复）。

  高级 / 自测（命令行）：
    powershell -ExecutionPolicy Bypass -File x_video_gui.ps1 -Headless "链接1" "链接2"
    -OutDir "D:\输出"        统一输出目录
    -NoMirror                禁用公开解析接口兜底
    -Proxy http://127.0.0.1:7890  手动指定代理
    -NoProxy                 强制直连
    -ForceRedownload         忽略完成标记重新下载
    -SmokeTest               只构建窗口不进入消息循环（自检用，不弹窗）

  依赖：同目录 bin\yt-dlp.exe（或桌面便携包 bin\、系统 PATH / winget）；
        curl.exe、PowerShell 5.1 为 Win10 1803+ / Win11 系统自带；
        bin\ffmpeg.exe 可选，用于合并音视频分离流。
#>
param(
    [switch]$Headless,
    [switch]$SmokeTest,
    [switch]$NoMirror,
    [switch]$Login,
    [switch]$NoProxy,
    [switch]$ForceRedownload,
    [string]$Proxy,
    [string]$OutDir,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Inputs
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$script:guiMode      = -not $Headless
$script:cancel       = $false
$script:busy         = $false
$script:defaultOutDir = Join-Path $env:USERPROFILE 'Downloads\X视频'
$script:targetOutDir = if ($OutDir) { $OutDir } else { $script:defaultOutDir }
$script:stateFile    = Join-Path $script:targetOutDir '.xdl_state.json'
$script:state        = @{}
$script:proxyUrl     = ''
$script:proxyHow     = ''
$script:noMirrorNow  = [bool]$NoMirror
$script:forceNow     = [bool]$ForceRedownload
# 托盘常驻状态：reallyExit 放行 FormClosing；exitPending 等批量循环收尾后再退出，
# 避免正在跑的 curl / yt-dlp 子进程变成孤儿。
$script:reallyExit    = $false
$script:exitPending   = $false
$script:trayHintShown = $false

# ---------------------------------------------------------------- 工具定位
function Find-BinDir {
    $cands = @(
        (Join-Path $PSScriptRoot 'bin'),
        (Join-Path $PSScriptRoot 'X视频下载-便携版\bin')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Container) { return $c } }
    return ''
}
$script:binDir = Find-BinDir

$script:yt = ''
if ($script:binDir) {
    $c = Join-Path $script:binDir 'yt-dlp.exe'
    if (Test-Path -LiteralPath $c) { $script:yt = $c }
}
if (-not $script:yt) {
    $cmd = Get-Command yt-dlp -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { $script:yt = $cmd.Source }
}
if (-not $script:yt) {
    $c = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\yt-dlp.exe'
    if (Test-Path -LiteralPath $c) { $script:yt = $c }
}

$script:curlExe = ''
$cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { $script:curlExe = $cmd.Source }
if (-not $script:curlExe) {
    $c = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $c) { $script:curlExe = $c }
}

$script:hasFfmpeg = $false
$script:ffArg = @()
if ($script:binDir -and (Test-Path -LiteralPath (Join-Path $script:binDir 'ffmpeg.exe'))) {
    $script:hasFfmpeg = $true
    $script:ffArg = @('--ffmpeg-location', $script:binDir)
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    $script:hasFfmpeg = $true
}

# ---------------------------------------------------------------- 代理
# Windows 环境变量名不区分大小写。宿主常同时注入 HTTPS_PROXY 与 https_proxy，
# Start-Process 复制环境块时会抛「Item has already been added」，子进程起不来。
# 先无条件清掉所有变体，再只写小写一份。
function Resolve-Proxy {
    $injected = ''
    foreach ($n in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $injected = $v.Trim(); break }
    }
    foreach ($n in @('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY',
                     'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY')) {
        try { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } catch { }
    }

    if ($NoProxy) {
        $script:proxyHow = '强制直连'
        return
    }
    # 手动 -Proxy 优先（防止误把推文链接当成代理地址）
    if ($Proxy -and $Proxy -match '^https?://' -and $Proxy -notmatch '(?:x\.com|twitter\.com)/') {
        $script:proxyUrl = $Proxy.Trim()
        $script:proxyHow = '命令行 -Proxy 指定'
    }
    if (-not $script:proxyUrl) {
        try {
            $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ($inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
                $script:proxyUrl = $inet.ProxyServer.Trim()
                $script:proxyHow = 'Windows 系统代理'
            }
        } catch { }
    }
    if (-not $script:proxyUrl -and $injected) {
        $script:proxyUrl = $injected
        $script:proxyHow = '环境变量'
    }
    if (-not $script:proxyUrl) {
        foreach ($port in @(7897, 7890, 10809, 1080, 2080, 33210)) {
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $t = $client.ConnectAsync('127.0.0.1', $port)
                if ($t.Wait(200) -and $client.Connected) {
                    $script:proxyUrl = "http://127.0.0.1:$port"
                    $script:proxyHow = "本地端口探测 $port"
                }
            } catch { } finally { $client.Dispose() }
            if ($script:proxyUrl) { break }
        }
    }
    if ($script:proxyUrl) {
        if ($script:proxyUrl -notmatch '^https?://') { $script:proxyUrl = 'http://' + $script:proxyUrl }
        try {
            [Environment]::SetEnvironmentVariable('http_proxy', $script:proxyUrl, 'Process')
            [Environment]::SetEnvironmentVariable('https_proxy', $script:proxyUrl, 'Process')
        } catch { }
    } else {
        $script:proxyHow = '直连（未检测到代理）'
    }
}
Resolve-Proxy

$script:proxyArg = @()
if ($script:proxyUrl) { $script:proxyArg = @('--proxy', $script:proxyUrl) }
$script:cookieArg = @()
$cookieFile = Join-Path $PSScriptRoot 'cookies.txt'
if ($Login) {
    $script:cookieArg = @('--cookies-from-browser', 'chrome')
} elseif (Test-Path -LiteralPath $cookieFile) {
    $script:cookieArg = @('--cookies', $cookieFile)
}
$script:netArg = @('--retries', '4', '--extractor-retries', '2', '--socket-timeout', '20')

# ---------------------------------------------------------------- 状态文件
function Load-State {
    $script:state = @{}
    if (-not (Test-Path -LiteralPath $script:stateFile -PathType Leaf)) { return }
    try {
        $j = Get-Content -LiteralPath $script:stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($j.items)) {
            if ($e.key) {
                $script:state[[string]$e.key] = @{
                    url  = [string]$e.url
                    file = [string]$e.file
                    done = [bool]$e.done
                    size = [long]$e.size
                }
            }
        }
    } catch { }
}
function Save-State {
    try {
        [System.IO.Directory]::CreateDirectory($script:targetOutDir) | Out-Null
        $items = @()
        foreach ($k in $script:state.Keys) {
            $v = $script:state[$k]
            $items += [pscustomobject]@{ key = [string]$k; url = $v.url; file = $v.file; done = [bool]$v.done; size = [long]$v.size }
        }
        $json = @{ items = @($items) } | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:stateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
Load-State

# ---------------------------------------------------------------- 链接处理
function Get-TweetId([string]$u) {
    if ($u -match '/status/(\d+)') { return $Matches[1] }
    return ''
}
function Test-IsX([string]$u) {
    return ($u -match '^https?://(?:www\.)?(?:x\.com|twitter\.com)/')
}
function Normalize-Url([string]$u) {
    $u = $u.Trim().Trim('"')
    if (Test-IsX $u) {
        $u = ($u -replace '[?#].*$', '' -replace '/(?:video|photo)/\d+/?$', '').TrimEnd('/')
    }
    return $u
}
# 输入可为：单个 URL、多行文本、空格分隔的多个 URL、本地 .txt 文件（每行一个链接）
function Expand-Input([string]$raw) {
    $s = $raw.Trim().Trim('"')
    if (-not $s) { return @() }
    if ($s -notmatch '^https?://' -and (Test-Path -LiteralPath $s -PathType Leaf -ErrorAction SilentlyContinue)) {
        try { $s = (Get-Content -LiteralPath $s -Raw -Encoding UTF8) } catch { return @() }
    }
    return @([regex]::Matches($s, 'https?://[^\s"<>]+') | ForEach-Object { $_.Value })
}

# ---------------------------------------------------------------- 直链解析
function Get-MirrorLinks([string]$tweetUrl) {
    $tail = $tweetUrl -replace '^https?://(?:www\.)?(?:x\.com|twitter\.com)/?', ''
    $tail = ($tail -replace '[?#].*$', '' -replace '/(?:video|photo)/\d+/?$', '').TrimEnd('/')
    if (-not $tail) { return @() }
    $structured = @()
    $regexed = @()
    foreach ($apiHost in @('api.fxtwitter.com', 'api.vxtwitter.com')) {
        $cargs = @('-s', '--max-time', '20', '--retry', '2')
        if ($script:proxyUrl) { $cargs += @('-x', $script:proxyUrl) }
        $cargs += "https://$apiHost/$tail"
        $raw = ''
        try { $raw = (& $script:curlExe @cargs 2>$null) -join "`n" } catch { continue }
        if (-not $raw) { continue }
        try {
            $j = $raw | ConvertFrom-Json
            foreach ($v in @($j.tweet.media.videos)) { if ($v.url -is [string] -and $v.url -match '^https?://') { $structured += $v.url } }
            foreach ($v in @($j.mediaURLs)) { if ($v -is [string] -and $v -match '^https?://') { $structured += $v } }
            foreach ($v in @($j.media_extended)) { if ($v.type -eq 'video' -and $v.url -is [string]) { $structured += $v.url } }
        } catch { }
        $clean = $raw -replace '\\/', '/'
        foreach ($m in [regex]::Matches($clean, 'https://video\.twimg\.com/[^"\s,]+?\.mp4(?:\?[^"\s,]*)?')) {
            $regexed += $m.Value
        }
    }
    $pick = @($structured | Where-Object { $_ -is [string] -and $_ -match '^https?://' })
    if ($pick.Count -eq 0) {
        $groups = @{}
        foreach ($u in $regexed) {
            $key = $u -replace '/vid/\d+x\d+/', '/vid/RES/'
            $h = 0
            if ($u -match '/vid/\d+x(\d+)/') { $h = [int]$Matches[1] }
            if (-not $groups.ContainsKey($key) -or $h -gt $groups[$key].H) {
                $groups[$key] = @{ H = $h; U = $u }
            }
        }
        $pick = @($groups.Values | ForEach-Object { $_.U })
    }
    $seen = @{}
    $final = @()
    foreach ($u in $pick) {
        $k = $u -replace '\?.*$', ''
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $final += $u }
    }
    return @($final)
}

function Get-DirectLinks([string]$u) {
    $isX = Test-IsX $u
    # 已经是直链（.mp4 / .webm / .mov / .m4v）时不必再让 yt-dlp 解析
    $leaf = ($u -split '[?#]')[0]
    if ($leaf -match '\.(mp4|m4v|webm|mov)$' -and -not $isX) { return @($u) }

    $callArgs = @() + $script:proxyArg + $script:cookieArg + $script:netArg +
                @('-g', '-f', 'best[ext=mp4]/best', '--no-warnings', $u)
    $out = @()
    try { $out = @(& $script:yt @callArgs 2>$null) } catch { }
    $links = @($out | Where-Object { $_ -is [string] -and $_ -match '^https?://' })
    if ($links.Count -eq 0 -and $isX -and -not $script:noMirrorNow) {
        $links = @(Get-MirrorLinks $u)
    }
    return @($links)
}

# ---------------------------------------------------------------- 输出文件名（续传关键：确定性）
function Get-TaskFile([string]$u, [string]$link, [int]$index) {
    $tid = Get-TweetId $u
    if (-not $tid) {
        $md5 = New-Object System.Security.Cryptography.MD5CryptoServiceProvider
        $tid = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($u)))).Replace('-', '').Substring(0, 10)
        $md5.Dispose()
    }
    $leaf = (($link -split '\?')[0] -split '/')[-1]
    $leaf = $leaf -replace '[\\/:*?"<>|]', '_'
    if ($leaf -notmatch '\.[a-z0-9]{2,4}$') { $leaf = "video_$index.mp4" }
    if ($leaf.Length -gt 60) { $leaf = $leaf.Substring($leaf.Length - 60) }
    return (Join-Path $script:targetOutDir ("{0}_{1}_{2}" -f $tid, $index, $leaf))
}

# ---------------------------------------------------------------- 日志
function Add-Log([string]$msg) {
    if ($script:guiMode) {
        try {
            $script:txtLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $msg`r`n")
            $script:txtLog.SelectionStart = $script:txtLog.TextLength
            $script:txtLog.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        } catch { }
    } else {
        Write-Host $msg
    }
}

# ---------------------------------------------------------------- 单次 curl 断点续传
# PowerShell 5.1 下 Start-Process -PassThru 读不到 ExitCode（恒为空），
# 因此用 curl -w 把 http_code / size_download 写进独立文件来判定结果。
function Invoke-CurlResume {
    param([string]$Link, [string]$OutFile, [object]$Lvi)

    $tag = [guid]::NewGuid().ToString('N')
    $wFile = Join-Path $env:TEMP ('xdl_' + $tag + '.w')
    $eFile = Join-Path $env:TEMP ('xdl_' + $tag + '.err')

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $before = 0
        if ([System.IO.File]::Exists($OutFile)) {
            try { $before = (Get-Item -LiteralPath $OutFile).Length } catch { }
        }
        $useResume = ($before -gt 0 -and $attempt -eq 0)

        $cargs = @('-L', '--fail', '--silent', '--show-error', '--retry', '5',
                   '--retry-delay', '2', '--connect-timeout', '20')
        if ($useResume) { $cargs += @('-C', '-') }
        $cargs += @('-o', $OutFile, '-w', '%{http_code} %{size_download} %{time_total}')
        if ($script:proxyUrl) { $cargs += @('-x', $script:proxyUrl) }
        $cargs += $Link

        $quoted = @($cargs | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' })
        $proc = $null
        $startErr = ''
        try {
            $proc = Start-Process -FilePath $script:curlExe -ArgumentList $quoted -PassThru `
                        -NoNewWindow -RedirectStandardOutput $wFile -RedirectStandardError $eFile -ErrorAction Stop
            while ($true) {
                if ($proc.WaitForExit(200)) { break }
                if ($script:guiMode -and $Lvi) {
                    try {
                        $cur = 0
                        if ([System.IO.File]::Exists($OutFile)) { $cur = (Get-Item -LiteralPath $OutFile).Length }
                        $Lvi.SubItems[2].Text = ('{0:N1} MB' -f ($cur / 1MB))
                    } catch { }
                    [System.Windows.Forms.Application]::DoEvents()
                }
                if ($script:cancel) {
                    try { $proc.Kill() } catch { }
                    $proc.WaitForExit(2000) | Out-Null
                    break
                }
            }
            try { $proc.WaitForExit() } catch { }
        } catch {
            $startErr = $_.Exception.Message
        }

        $wText = ''
        if ([System.IO.File]::Exists($wFile)) {
            try { $wText = ([System.IO.File]::ReadAllText($wFile)).Trim() } catch { }
            try { [System.IO.File]::Delete($wFile) } catch { }
        }
        $eText = ''
        if ([System.IO.File]::Exists($eFile)) {
            try { $eText = ([System.IO.File]::ReadAllText($eFile)).Trim() } catch { }
            try { [System.IO.File]::Delete($eFile) } catch { }
        }

        if ($script:cancel) {
            $sz = 0
            if ([System.IO.File]::Exists($OutFile)) { try { $sz = (Get-Item -LiteralPath $OutFile).Length } catch { } }
            return @{ Ok = $false; Cancelled = $true; Bytes = $sz; Error = '' }
        }

        $parts = @($wText -split '\s+')
        $code = ''
        if ($parts.Count -gt 0) { $code = $parts[0] }
        $downloaded = 0
        if ($parts.Count -gt 1) { try { $downloaded = [long]$parts[1] } catch { } }
        $size = 0
        if ([System.IO.File]::Exists($OutFile)) { try { $size = (Get-Item -LiteralPath $OutFile).Length } catch { } }

        # 服务器忽略 Range、返回 200 全量时 curl 可能把内容追加到半成品后面，
        # 会损坏文件。删掉半成品，第二轮从头完整重下。
        if ($useResume -and $code -eq '200' -and $size -gt $before) {
            Add-Log '  服务器不支持续传（返回 200），改为完整重下。'
            try { [System.IO.File]::Delete($OutFile) } catch { }
            continue
        }

        # 续传必须收到 206。若服务器不支持 Range，curl 会报错退出但 -w 仍打印
        # 「200 0 ...」，绝不能把没动过的半成品当成成功文件并标记完成。
        $ok = ($code -eq '200' -or $code -eq '206') -and ($size -gt 0) -and ($downloaded -gt 0)
        if ($useResume -and $code -ne '206') { $ok = $false }
        if ($ok) {
            return @{ Ok = $true; Cancelled = $false; Bytes = $size;
                      Error = ''; Resumed = $useResume; Code = $code }
        }
        $msg = "HTTP $code（本次传输 $downloaded 字节）"
        if ($startErr) { $msg += " · $startErr" }
        elseif ($eText) { $msg += " · " + ($eText -split "[\r\n]+" | Select-Object -Last 1) }
        # 416 通常意味着文件其实已经下完（服务器认为 Range 超出）
        if ($code -eq '416' -and $size -gt 0) {
            return @{ Ok = $true; Cancelled = $false; Bytes = $size; Error = ''; Resumed = $false; Code = '416' }
        }
        if ($attempt -eq 0 -and $before -gt 0) {
            Add-Log "  续传失败（$msg），删除半成品重试完整下载。"
            try { [System.IO.File]::Delete($OutFile) } catch { }
            continue
        }
        return @{ Ok = $false; Cancelled = $false; Bytes = $size; Error = $msg }
    }
    return @{ Ok = $false; Cancelled = $false; Bytes = 0; Error = '下载失败' }
}

# ---------------------------------------------------------------- 分片 / 分离流：yt-dlp 原生下载
function Invoke-YtDlpNative {
    param([string]$Url, [string]$Prefix, [object]$Lvi)

    $outTpl = Join-Path $script:targetOutDir ($Prefix + '.%(ext)s')
    $callArgs = @() + $script:proxyArg + $script:cookieArg + $script:netArg + $script:ffArg +
                @('-f', 'bv*+ba/b', '--merge-output-format', 'mp4',
                  '--continue', '--no-overwrites', '--no-warnings',
                  '--trim-filenames', '80', '-o', $outTpl, $Url)
    $tag = [guid]::NewGuid().ToString('N')
    $oFile = Join-Path $env:TEMP ('xdl_' + $tag + '.out')
    $eFile = Join-Path $env:TEMP ('xdl_' + $tag + '.err')
    $quoted = @($callArgs | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' })
    try {
        $proc = Start-Process -FilePath $script:yt -ArgumentList $quoted -PassThru `
                    -NoNewWindow -RedirectStandardOutput $oFile -RedirectStandardError $eFile -ErrorAction Stop
        while ($true) {
            if ($proc.WaitForExit(200)) { break }
            if ($script:guiMode) { [System.Windows.Forms.Application]::DoEvents() }
            if ($script:cancel) {
                try { $proc.Kill() } catch { }
                $proc.WaitForExit(2000) | Out-Null
                break
            }
        }
        try { $proc.WaitForExit() } catch { }
    } catch { }
    $logText = ''
    foreach ($f in @($oFile, $eFile)) {
        if ([System.IO.File]::Exists($f)) {
            try { $logText += ([System.IO.File]::ReadAllText($f)) } catch { }
            try { [System.IO.File]::Delete($f) } catch { }
        }
    }
    $files = @(Get-ChildItem -LiteralPath $script:targetOutDir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like ($Prefix + '.*') -and
                              $_.Extension -notin @('.part', '.ytdl') -and $_.Length -gt 0 })
    if ($script:cancel) { return @{ Ok = $false; Cancelled = $true; Bytes = 0; Error = '' } }
    if ($files.Count -gt 0) {
        $f = $files[0]
        return @{ Ok = $true; Cancelled = $false; Bytes = $f.Length; File = $f.FullName; Error = '' }
    }
    $tail = (($logText -split "[\r\n]+" | Where-Object { $_ } | Select-Object -Last 2) -join ' | ')
    return @{ Ok = $false; Cancelled = $false; Bytes = 0; Error = $tail }
}

# ---------------------------------------------------------------- 批量引擎（窗口 / 命令行共用）
function Invoke-Batch {
    param([string[]]$Urls, [object[]]$Items)

    $okCount = 0; $failCount = 0; $outs = @()
    $total = @($Urls).Count
    if ($total -eq 0) { return @{ Ok = 0; Fail = 0; Outs = @() } }

    try { [System.IO.Directory]::CreateDirectory($script:targetOutDir) | Out-Null } catch { }
    if ($script:guiMode) {
        $script:progress.Maximum = $total
        $script:progress.Value = 0
        $script:btnStart.Enabled = $false
        $script:btnStop.Enabled = $true
        $script:btnPaste.Enabled = $false
        $script:btnAddUrl.Enabled = $false
        $script:btnImport.Enabled = $false
        $script:btnRemove.Enabled = $false
        $script:btnClear.Enabled = $false
    }
    $script:busy = $true
    $script:cancel = $false
    Add-Log "开始批量下载，共 $total 项 → $($script:targetOutDir)"

    for ($i = 0; $i -lt $total; $i++) {
        if ($script:cancel) { Add-Log '已停止，跳过剩余任务。'; break }
        $u = [string](Normalize-Url $Urls[$i])
        $lvi = $null
        if ($Items -and $Items.Count -gt $i) { $lvi = $Items[$i] }
        $short = if ($u.Length -gt 68) { $u.Substring(0, 68) + '…' } else { $u }

        if ($script:guiMode) {
            $script:lblStatus.Text = "正在处理 ($($i + 1)/$total)：$short"
            $script:progress.Value = $i
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($lvi) { $lvi.SubItems[0].Text = '解析中…'; $lvi.SubItems[3].Text = '' }
        Add-Log "[$($i + 1)/$total] $u"

        # 已完成项：直接跳过（除非强制重下）
        $existing = @($script:state.Keys | Where-Object { $script:state[$_].url -eq $u -and $script:state[$_].done })
        if ($existing.Count -gt 0 -and -not $script:forceNow) {
            $allThere = $true
            foreach ($k in $existing) {
                if (-not [System.IO.File]::Exists($script:state[$k].file)) { $allThere = $false }
            }
            if ($allThere) {
                $okCount++
                if ($lvi) { $lvi.SubItems[0].Text = '✓ 已完成'; $lvi.SubItems[3].Text = '已存在，跳过' }
                Add-Log '  已完成，跳过（如需重下请勾选「强制重新下载」）。'
                if ($script:guiMode) { $script:progress.Value = $i + 1; [System.Windows.Forms.Application]::DoEvents() }
                continue
            }
        }

        $links = @(Get-DirectLinks $u)
        if ($links.Count -eq 0) {
            $failCount++
            if ($lvi) { $lvi.SubItems[0].Text = '✗ 失败'; $lvi.SubItems[3].Text = '无法解析直链' }
            Add-Log '  ✗ 未解析到直链：检查代理能否访问 X；受限推文可试公开解析接口；需登录可放 cookies.txt。'
            if ($script:guiMode) { $script:progress.Value = $i + 1; [System.Windows.Forms.Application]::DoEvents() }
            continue
        }
        Add-Log "  解析到 $($links.Count) 条直链"

        $allOk = $true
        $resumedAny = $false
        for ($j = 0; $j -lt $links.Count; $j++) {
            if ($script:cancel) { break }
            $link = [string]$links[$j]
            $outFile = Get-TaskFile $u $link ($j + 1)
            $key = $outFile
            $script:state[$key] = @{ url = $u; file = $outFile; done = $false; size = 0 }
            # 先落盘：进程被强杀 / 断电时，窗口下次启动仍能恢复这条未完成任务
            Save-State

            # 非单文件直链（m3u8 / 分离流）→ yt-dlp 原生下载
            $pathPart = ($link -split '\?')[0]
            if ($pathPart -match '\.m3u8' -or $pathPart -notmatch '\.(mp4|m4v|webm|mov)$') {
                Add-Log '  分片 / 分离流，改用 yt-dlp 原生下载（.part 支持续传）。'
                $prefix = [IO.Path]::GetFileNameWithoutExtension($outFile)
                $r = Invoke-YtDlpNative -Url $u -Prefix $prefix -Lvi $lvi
            } else {
                $r = Invoke-CurlResume -Link $link -OutFile $outFile -Lvi $lvi
            }

            if ($r.Cancelled) {
                if ($lvi) {
                    $lvi.SubItems[0].Text = '⏸ 已暂停'
                    $lvi.SubItems[3].Text = '可续传'
                    if ($r.Bytes -gt 0) { $lvi.SubItems[2].Text = ('{0:N1} MB' -f ($r.Bytes / 1MB)) }
                }
                $script:state[$key] = @{ url = $u; file = $outFile; done = $false; size = [long]$r.Bytes }
                Save-State
                Add-Log "  ⏸ 已停止，保留 $([math]::Round($r.Bytes / 1MB, 1)) MB 半成品，下次自动续传。"
                break
            }
            if (-not $r.Ok) {
                $allOk = $false
                $script:state[$key] = @{ url = $u; file = $outFile; done = $false; size = [long]$r.Bytes }
                Add-Log "  ✗ 下载失败：$($r.Error)"
                continue
            }
            $finalFile = if ($r.File) { $r.File } else { $outFile }
            $script:state[$key] = @{ url = $u; file = $finalFile; done = $true; size = [long]$r.Bytes }
            $outs += $finalFile
            $resumedAny = $resumedAny -or [bool]$r.Resumed
            Save-State
            if ($lvi) { $lvi.SubItems[2].Text = ('{0:N1} MB' -f ($r.Bytes / 1MB)) }
            $suffix = ''
            if ($r.Resumed) { $suffix = '（续传）' }
            Add-Log "  ✓ 完成${suffix}：$([IO.Path]::GetFileName($finalFile)) · $([math]::Round($r.Bytes / 1MB, 1)) MB"
        }

        if ($script:cancel) { break }
        if ($allOk) {
            $okCount++
            if ($lvi) { $lvi.SubItems[0].Text = '✓ 成功'; $lvi.SubItems[3].Text = "$($links.Count) 个文件$(if ($resumedAny) { ' · 含续传' } else { '' })" }
        } else {
            $failCount++
            if ($lvi) { $lvi.SubItems[0].Text = '✗ 失败'; $lvi.SubItems[3].Text = '见日志，可重跑续传' }
        }
        Save-State
        if ($script:guiMode) {
            $script:progress.Value = $i + 1
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    if ($script:guiMode) {
        $script:lblStatus.Text = "完成：成功 $okCount 项，失败 $failCount 项。"
        if (-not $script:cancel) { $script:progress.Value = $script:progress.Maximum }
        $script:btnStart.Enabled = $true
        $script:btnStop.Enabled = $false
        $script:btnPaste.Enabled = $true
        $script:btnAddUrl.Enabled = $true
        $script:btnImport.Enabled = $true
        $script:btnRemove.Enabled = $true
        $script:btnClear.Enabled = $true
    }
    $script:busy = $false
    $script:cancel = $false
    Add-Log "批量结束：成功 $okCount，失败 $failCount。"
    # 托盘菜单里请求了「退出」且当时正在下载：这里子进程已全部收尾，才真正退出
    if ($script:exitPending) { Complete-AppExit }
    return @{ Ok = $okCount; Fail = $failCount; Outs = $outs }
}

# ---------------------------------------------------------------- 无界面批量模式
if ($Headless) {
    if (-not $script:yt) { Write-Host 'ERROR: 未找到 yt-dlp.exe' -ForegroundColor Red; exit 1 }
    if (-not $script:curlExe) { Write-Host 'ERROR: 未找到 curl.exe' -ForegroundColor Red; exit 1 }
    Write-Host "yt-dlp: $($script:yt)"
    Write-Host "curl:   $($script:curlExe)"
    Write-Host "代理:   $(if ($script:proxyUrl) { "$($script:proxyUrl) ($($script:proxyHow))" } else { $script:proxyHow })"
    Write-Host "输出:   $($script:targetOutDir)"
    $urls = @()
    foreach ($raw in @($Inputs)) { $urls += @(Expand-Input $raw) }
    $urls = @($urls | ForEach-Object { Normalize-Url $_ } | Select-Object -Unique)
    if ($urls.Count -eq 0) { Write-Host 'ERROR: 没有可用的链接' -ForegroundColor Red; exit 1 }
    Write-Host "共 $($urls.Count) 项待下载"
    $r = Invoke-Batch -Urls $urls -Items $null
    foreach ($o in $r.Outs) { Write-Host "OUT: $o" }
    if ($r.Fail -gt 0 -and $r.Ok -eq 0) { exit 1 }
    exit 0
}

# ---------------------------------------------------------------- 窗口界面
[System.Windows.Forms.Application]::EnableVisualStyles()
$font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'X 视频批量下载 · 支持断点续传'
$script:form.Size = New-Object System.Drawing.Size(920, 700)
$script:form.MinimumSize = New-Object System.Drawing.Size(780, 600)
$script:form.StartPosition = 'CenterScreen'
$script:form.Font = $font
$script:form.ShowInTaskbar = $true

$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = '粘贴或导入多条推文链接（一行一条）→ 点「开始批量下载」。点右上角 × 收进系统托盘后台继续下载；中途停止会保留半成品，下次自动续传。'
$lblTip.Location = New-Object System.Drawing.Point(16, 12)
$lblTip.Size = New-Object System.Drawing.Size(880, 24)
$script:form.Controls.Add($lblTip)

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.Location = New-Object System.Drawing.Point(16, 40)
$script:lv.Size = New-Object System.Drawing.Size(872, 250)
$script:lv.View = 'Details'
$script:lv.FullRowSelect = $true
$script:lv.GridLines = $true
$script:lv.AllowDrop = $true
$script:lv.MultiSelect = $true
$script:lv.Columns.Add('状态', 100) | Out-Null
$script:lv.Columns.Add('链接', 470) | Out-Null
$script:lv.Columns.Add('已下载', 110) | Out-Null
$script:lv.Columns.Add('结果', 175) | Out-Null
$script:form.Controls.Add($script:lv)

function Add-TaskUrl([string]$raw) {
    $found = @(Expand-Input $raw)
    $added = 0
    foreach ($u in $found) {
        $n = Normalize-Url $u
        if (-not $n) { continue }
        $exists = @($script:lv.Items | ForEach-Object { [string]$_.Tag })
        if ($exists -contains $n) { continue }
        $lvi = New-Object System.Windows.Forms.ListViewItem('等待')
        $lvi.SubItems.Add($n) | Out-Null
        $lvi.SubItems.Add('') | Out-Null
        $lvi.SubItems.Add('') | Out-Null
        $lvi.Tag = $n
        $script:lv.Items.Add($lvi) | Out-Null
        $added++
    }
    return $added
}
function Update-Count {
    $n = $script:lv.Items.Count
    $script:lblCount.Text = "待下载：$n 项"
    $script:btnStart.Text = "开始批量下载 ($n)"
    $script:btnStart.Enabled = ($n -gt 0 -and [bool]$script:yt -and [bool]$script:curlExe)
}

$script:btnPaste = New-Object System.Windows.Forms.Button
$script:btnPaste.Text = '粘贴链接'
$script:btnPaste.Location = New-Object System.Drawing.Point(16, 300)
$script:btnPaste.Size = New-Object System.Drawing.Size(100, 30)
$script:form.Controls.Add($script:btnPaste)

$script:btnAddUrl = New-Object System.Windows.Forms.Button
$script:btnAddUrl.Text = '添加网址…'
$script:btnAddUrl.Location = New-Object System.Drawing.Point(122, 300)
$script:btnAddUrl.Size = New-Object System.Drawing.Size(100, 30)
$script:form.Controls.Add($script:btnAddUrl)

$script:btnImport = New-Object System.Windows.Forms.Button
$script:btnImport.Text = '导入 txt…'
$script:btnImport.Location = New-Object System.Drawing.Point(228, 300)
$script:btnImport.Size = New-Object System.Drawing.Size(100, 30)
$script:form.Controls.Add($script:btnImport)

$script:btnRemove = New-Object System.Windows.Forms.Button
$script:btnRemove.Text = '移除选中'
$script:btnRemove.Location = New-Object System.Drawing.Point(334, 300)
$script:btnRemove.Size = New-Object System.Drawing.Size(95, 30)
$script:form.Controls.Add($script:btnRemove)

$script:btnClear = New-Object System.Windows.Forms.Button
$script:btnClear.Text = '清空列表'
$script:btnClear.Location = New-Object System.Drawing.Point(435, 300)
$script:btnClear.Size = New-Object System.Drawing.Size(90, 30)
$script:form.Controls.Add($script:btnClear)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '待下载：0 项'
$lblCount.Location = New-Object System.Drawing.Point(545, 306)
$lblCount.Size = New-Object System.Drawing.Size(340, 22)
$script:form.Controls.Add($lblCount)
$script:lblCount = $lblCount

$script:chkOut = New-Object System.Windows.Forms.CheckBox
$script:chkOut.Text = '统一输出到：'
$script:chkOut.Location = New-Object System.Drawing.Point(16, 342)
$script:chkOut.Size = New-Object System.Drawing.Size(115, 26)
$script:form.Controls.Add($script:chkOut)

$script:txtOut = New-Object System.Windows.Forms.TextBox
$script:txtOut.Location = New-Object System.Drawing.Point(132, 342)
$script:txtOut.Size = New-Object System.Drawing.Size(650, 26)
$script:txtOut.Text = $script:targetOutDir
$script:txtOut.Enabled = $false
$script:form.Controls.Add($script:txtOut)

$script:btnBrowse = New-Object System.Windows.Forms.Button
$script:btnBrowse.Text = '浏览…'
$script:btnBrowse.Location = New-Object System.Drawing.Point(790, 341)
$script:btnBrowse.Size = New-Object System.Drawing.Size(98, 28)
$script:btnBrowse.Enabled = $false
$script:form.Controls.Add($script:btnBrowse)

$script:chkForce = New-Object System.Windows.Forms.CheckBox
$script:chkForce.Text = '强制重新下载（忽略已完成标记）'
$script:chkForce.Location = New-Object System.Drawing.Point(16, 374)
$script:chkForce.Size = New-Object System.Drawing.Size(270, 26)
$script:form.Controls.Add($script:chkForce)

$script:chkNoMirror = New-Object System.Windows.Forms.CheckBox
$script:chkNoMirror.Text = '禁用公开解析接口兜底'
$script:chkNoMirror.Location = New-Object System.Drawing.Point(292, 374)
$script:chkNoMirror.Size = New-Object System.Drawing.Size(200, 26)
$script:form.Controls.Add($script:chkNoMirror)

$script:chkOpen = New-Object System.Windows.Forms.CheckBox
$script:chkOpen.Text = '完成后打开输出文件夹'
$script:chkOpen.Location = New-Object System.Drawing.Point(500, 374)
$script:chkOpen.Size = New-Object System.Drawing.Size(200, 26)
$script:chkOpen.Checked = $true
$script:form.Controls.Add($script:chkOpen)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = '就绪。'
$script:lblStatus.Location = New-Object System.Drawing.Point(16, 406)
$script:lblStatus.Size = New-Object System.Drawing.Size(872, 22)
$script:form.Controls.Add($script:lblStatus)

$script:progress = New-Object System.Windows.Forms.ProgressBar
$script:progress.Location = New-Object System.Drawing.Point(16, 430)
$script:progress.Size = New-Object System.Drawing.Size(872, 18)
$script:progress.Minimum = 0
$script:progress.Maximum = 100
$script:form.Controls.Add($script:progress)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = '运行日志（断点续传、代理、解析结果都记在这里）'
$lblLogTitle.Location = New-Object System.Drawing.Point(16, 454)
$lblLogTitle.Size = New-Object System.Drawing.Size(400, 20)
$script:form.Controls.Add($lblLogTitle)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(16, 476)
$script:txtLog.Size = New-Object System.Drawing.Size(872, 112)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.WordWrap = $false
$script:txtLog.BackColor = [System.Drawing.Color]::White
$script:form.Controls.Add($script:txtLog)

$script:btnStart = New-Object System.Windows.Forms.Button
$script:btnStart.Text = '开始批量下载 (0)'
$script:btnStart.Location = New-Object System.Drawing.Point(16, 598)
$script:btnStart.Size = New-Object System.Drawing.Size(180, 36)
$script:form.Controls.Add($script:btnStart)

$script:btnStop = New-Object System.Windows.Forms.Button
$script:btnStop.Text = '停止（可续传）'
$script:btnStop.Location = New-Object System.Drawing.Point(204, 598)
$script:btnStop.Size = New-Object System.Drawing.Size(120, 36)
$script:btnStop.Enabled = $false
$script:form.Controls.Add($script:btnStop)

$btnOpenOut = New-Object System.Windows.Forms.Button
$btnOpenOut.Text = '打开输出目录'
$btnOpenOut.Location = New-Object System.Drawing.Point(332, 598)
$btnOpenOut.Size = New-Object System.Drawing.Size(120, 36)
$script:form.Controls.Add($btnOpenOut)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '退出程序'
$btnClose.Location = New-Object System.Drawing.Point(798, 598)
$btnClose.Size = New-Object System.Drawing.Size(90, 36)
$script:form.Controls.Add($btnClose)

$lblFoot = New-Object System.Windows.Forms.Label
$footYt = if ($script:yt) { '已就绪' } else { '未找到' }
$footFf = if ($script:hasFfmpeg) { '已就绪' } else { '未找到（自动选单一 MP4）' }
$footProxy = if ($script:proxyUrl) { "$($script:proxyUrl)（$($script:proxyHow)）" } else { $script:proxyHow }
$lblFoot.Text = "yt-dlp: $footYt    |    ffmpeg: $footFf    |    代理: $footProxy"
$lblFoot.Location = New-Object System.Drawing.Point(16, 642)
$lblFoot.Size = New-Object System.Drawing.Size(872, 20)
$lblFoot.ForeColor = [System.Drawing.Color]::Gray
$script:form.Controls.Add($lblFoot)

# ---------------------------------------------------------------- 系统托盘
# 点右上角 × 只隐藏窗口，进程和下载任务继续在后台跑。
function New-TrayIcon {
    try {
        $bmp = [System.Drawing.Bitmap]::new(32, 32)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(29, 155, 240))
        $wh = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        $g.FillEllipse($bg, 1, 1, 30, 30)
        $g.FillRectangle($wh, 13, 8, 6, 11)          # 向下箭头的竖杆
        [System.Drawing.Point[]]$tri = @(
            [System.Drawing.Point]::new(7, 18),
            [System.Drawing.Point]::new(25, 18),
            [System.Drawing.Point]::new(16, 27)
        )
        $g.FillPolygon($wh, $tri)                     # 箭头三角形
        $tmp = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $ico = [System.Drawing.Icon]($tmp.Clone())    # Clone 后再释放 bitmap，图标仍可用
        $tmp.Dispose(); $wh.Dispose(); $bg.Dispose(); $g.Dispose(); $bmp.Dispose()
        return $ico
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}
function Show-MainWindow {
    try {
        $script:form.Show()
        $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $script:form.ShowInTaskbar = $true
        $script:form.BringToFront()
        $script:form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}
function Complete-AppExit {
    if ($script:reallyExit) { return }
    $script:reallyExit = $true
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }
    try { [System.Windows.Forms.Application]::Exit() } catch { }
}
function Request-AppExit {
    if ($script:busy) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            '正在下载，确定要停止并退出吗？已下载的部分会保留，下次可续传。',
            '确认退出', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        # 不立刻结束进程：先让批量循环把 curl / yt-dlp 子进程收尾，再由它真正退出
        $script:exitPending = $true
        $script:cancel = $true
        Add-Log '已请求退出，当前任务结束后程序会自动关闭。'
        return
    }
    Complete-AppExit
}

$script:tray = New-Object System.Windows.Forms.NotifyIcon
try { $script:tray.Icon = New-TrayIcon } catch { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }
$script:tray.Text = 'X 视频批量下载'
$script:trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $script:trayMenu.Items.Add('显示主窗口')
$miShow.Add_Click({ Show-MainWindow })
$script:trayMenu.Items.Add('-') | Out-Null
$miExit = $script:trayMenu.Items.Add('退出程序')
$miExit.Add_Click({ Request-AppExit })
$script:tray.ContextMenuStrip = $script:trayMenu
$script:tray.Add_DoubleClick({ Show-MainWindow })
$script:tray.Add_BalloonTipClicked({ Show-MainWindow })
if (-not $SmokeTest) { $script:tray.Visible = $true }

# ---------------------------------------------------------------- 事件
$script:lv.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) -or
        $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) {
        $e.Effect = 'Copy'
    }
})
$script:lv.Add_DragDrop({
    param($sender, $e)
    $added = 0
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        foreach ($p in $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)) {
            $added += Add-TaskUrl $p
        }
    } else {
        $txt = [string]$e.Data.GetData([System.Windows.Forms.DataFormats]::Text)
        $added += Add-TaskUrl $txt
    }
    Update-Count
    Add-Log "拖放添加 $added 项。"
})

$script:btnPaste.Add_Click({
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { }
    if (-not $clip) {
        [System.Windows.Forms.MessageBox]::Show('剪贴板为空。请先复制一条或多条链接（一行一条）。', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $n = Add-TaskUrl $clip
    Update-Count
    Add-Log "从剪贴板添加 $n 项。"
})
$script:btnAddUrl.Add_Click({
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { }
    $default = ''
    if ($clip -match '^https?://') { $default = ($clip.Trim() -split "[\r\n]+")[0] }
    $u = [Microsoft.VisualBasic.Interaction]::InputBox('输入视频 / 推文链接（http/https 开头）：', '添加网址', $default)
    if ($u -and $u.Trim()) {
        $n = Add-TaskUrl $u.Trim()
        Update-Count
        Add-Log "添加网址 $n 项。"
    }
})
$script:btnImport.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = '链接清单|*.txt|所有文件|*.*'
    $dlg.Title = '选择 txt（每行一个链接）'
    $dlg.Multiselect = $true
    if ($dlg.ShowDialog() -eq 'OK') {
        $n = 0
        foreach ($f in $dlg.FileNames) { $n += Add-TaskUrl $f }
        Update-Count
        Add-Log "导入 txt，新增 $n 项。"
    }
})
$script:btnRemove.Add_Click({
    foreach ($it in @($script:lv.SelectedItems)) { $script:lv.Items.Remove($it) }
    Update-Count
})
$script:btnClear.Add_Click({
    $script:lv.Items.Clear()
    Update-Count
    Add-Log '已清空列表（已下载的半成品文件仍保留，可重新加入链接继续续传）。'
})
$script:chkOut.Add_CheckedChanged({
    $script:txtOut.Enabled = $script:chkOut.Checked
    $script:btnBrowse.Enabled = $script:chkOut.Checked
})
$script:chkOut.Checked = $false
$script:btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择视频保存文件夹'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { $script:txtOut.Text = $dlg.SelectedPath }
})
$script:btnStart.Add_Click({
    $n = $script:lv.Items.Count
    if ($n -eq 0) { return }
    if (-not $script:yt -or -not $script:curlExe) {
        [System.Windows.Forms.MessageBox]::Show('未找到 yt-dlp.exe 或 curl.exe。请把便携包里的 bin 文件夹复制到本脚本旁边。', '缺少组件', 'OK', 'Error') | Out-Null
        return
    }
    if ($script:chkOut.Checked -and $script:txtOut.Text.Trim()) {
        $script:targetOutDir = $script:txtOut.Text.Trim()
    } else {
        $script:targetOutDir = $script:defaultOutDir
    }
    $script:stateFile = Join-Path $script:targetOutDir '.xdl_state.json'
    Load-State
    $script:noMirrorNow = [bool]$script:chkNoMirror.Checked
    $script:forceNow    = [bool]$script:chkForce.Checked
    foreach ($it in @($script:lv.Items)) {
        if ($it.SubItems[0].Text -ne '✓ 已完成') {
            $it.SubItems[0].Text = '等待'
            $it.SubItems[3].Text = ''
        }
    }
    $urls = @($script:lv.Items | ForEach-Object { [string]$_.Tag })
    $items = @($script:lv.Items)
    $r = Invoke-Batch -Urls $urls -Items $items
    if ($script:chkOpen.Checked -and $r.Ok -gt 0 -and -not $script:reallyExit) {
        try { Start-Process explorer.exe -ArgumentList ('"' + $script:targetOutDir + '"') } catch { }
    }
    $doneText = "批量下载结束：成功 $($r.Ok) 项，失败 $($r.Fail) 项。未完成的可再点「开始」续传。"
    if ($script:form.Visible -and -not $script:reallyExit) {
        [System.Windows.Forms.MessageBox]::Show($doneText, '完成', 'OK', 'Information') | Out-Null
    } elseif (-not $script:reallyExit) {
        # 窗口收在托盘时，用气泡通知代替会突然弹出的对话框
        try { $script:tray.ShowBalloonTip(5000, '批量下载完成', $doneText, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
})
$script:btnStop.Add_Click({
    $script:cancel = $true
    $script:lblStatus.Text = '正在停止…当前文件会保留，可续传。'
    Add-Log '收到停止请求，当前下载将保留半成品以便续传。'
})
$btnOpenOut.Add_Click({
    $d = if ($script:chkOut.Checked -and $script:txtOut.Text.Trim()) { $script:txtOut.Text.Trim() } else { $script:defaultOutDir }
    try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { }
    try { Start-Process explorer.exe -ArgumentList ('"' + $d + '"') } catch { }
})
$btnClose.Add_Click({ Request-AppExit })
$script:form.Add_FormClosing({
    param($sender, $e)
    if ($script:reallyExit) { return }   # 托盘菜单 / 「退出程序」按钮 / 系统关机：放行
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        # 点右上角 ×：取消关闭、隐藏窗口、留在托盘，任务继续在后台跑
        $e.Cancel = $true
        try {
            $script:form.Hide()
            $script:tray.Visible = $true
            if (-not $script:trayHintShown) {
                $script:trayHintShown = $true
                $script:tray.ShowBalloonTip(4000, 'X 视频批量下载',
                    '点 × 不会退出，下载在后台继续。双击图标恢复窗口，右键可退出程序。',
                    [System.Windows.Forms.ToolTipIcon]::Info)
            }
        } catch { }
        Add-Log '窗口已收进系统托盘（程序未退出，任务在后台继续）。'
        return
    }
    # 关机 / 任务管理器结束 / Application.Exit：先停后台子进程，再清理托盘图标
    if ($script:busy) { $script:cancel = $true }
    $script:reallyExit = $true
    try { $script:tray.Visible = $false; $script:tray.Dispose() } catch { }
})
$script:form.Add_Shown({ $script:form.Activate() })

# 预加载：bat 图标拖放 / 命令行传入的链接
if ($Inputs -and $Inputs.Count -gt 0) {
    foreach ($raw in $Inputs) { Add-TaskUrl $raw | Out-Null }
}
# 恢复上次未完成的任务（跨会话断点续传）
$resumeUrls = @($script:state.Values | Where-Object { -not $_.done -and $_.url } | ForEach-Object { $_.url } | Select-Object -Unique)
foreach ($u in $resumeUrls) { Add-TaskUrl $u | Out-Null }
Update-Count
Add-Log "就绪。yt-dlp: $footYt；代理: $footProxy"
if ($resumeUrls.Count -gt 0) { Add-Log "已恢复 $($resumeUrls.Count) 个未完成任务，点「开始」即可从已下载字节续传。" }

# 构建自检：构造窗体 / 控件 / 事件 / 列表但不进入消息循环
if ($SmokeTest) {
    Write-Host "GUI-BUILD-OK title=$($script:form.Text) controls=$($script:form.Controls.Count) tasks=$($script:lv.Items.Count) startBtn=$($script:btnStart.Text) yt=$(if ($script:yt) { 'yes' } else { 'no' }) curl=$(if ($script:curlExe) { 'yes' } else { 'no' }) tray=$(if ($script:tray.Icon) { 'yes' } else { 'no' }) trayItems=$($script:trayMenu.Items.Count)"
    if ($script:lv.Items.Count -gt 0) { Write-Host "  firstTask=$($script:lv.Items[0].Tag)" }
    try { $script:tray.Dispose() } catch { }
    exit 0
}

try {
    [System.Windows.Forms.Application]::Run($script:form)
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '窗口运行出错', 'OK', 'Error') | Out-Null
}
