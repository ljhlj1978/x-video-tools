<#
  视频下载助手 v3（便携版）：X 专用 + 通用站点双模式
  用法一：复制推文链接，双击「下载X视频.bat」
  用法二：把推文链接（可多个）拖到「下载X视频.bat」图标上
  用法三：双击「获取X视频直链-给FDM.bat」，取得 MP4 直链并自动复制，在 FDM 里 Ctrl+V 新建下载
  用法四：复制任意视频链接或拖到「通用视频下载.bat」上，下载到「下载\视频下载」
          （通用模式保留完整 URL / 查询串，不做 X 专属规范化与兜底）

  整个文件夹可以直接拷贝到别的 Windows 10/11 电脑使用。
  依赖：同目录 bin\yt-dlp.exe（已附带）；curl.exe 为 Win10/11 系统自带；PowerShell 为系统自带。
  bin\ 里已附带 ffmpeg.exe 用于合并音视频分离流；删掉它也能用（自动改选单一 MP4）。
  代理：自动按「-Proxy 参数 > Windows 系统代理 > 环境变量 > 常见本地代理端口」顺序探测。

  受限 / 需登录的推文，常规解析拿不到时会自动改用公开解析接口
  （api.fxtwitter.com / api.vxtwitter.com，仅发送公开推文 ID，不发送账号信息）。
  参数：-Generic    通用模式：接受任意 http(s) 链接，保留查询串，禁用 X 专属兜底
        -Login      强制读取 Chrome 登录态（需先完全关闭 Chrome）
        -NoMirror   禁用公开解析接口兜底
        -Proxy      手动指定代理，如 -Proxy http://127.0.0.1:7890
        -NoProxy    强制直连（海外网络）
  若把导出的 cookies.txt 放在本脚本同目录，会自动使用。
#>
param(
    [switch]$OnlyLink,
    [switch]$Generic,
    [switch]$Login,
    [switch]$NoMirror,
    [switch]$NoProxy,
    [string]$Proxy,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Urls
)

$ErrorActionPreference = 'Continue'
if ($Generic) {
    $OutDir = Join-Path $env:USERPROFILE 'Downloads\视频下载'
    Write-Host '=== 通用视频下载助手 v3（任意站点）===' -ForegroundColor Cyan
} else {
    $OutDir = Join-Path $env:USERPROFILE 'Downloads\X视频'
    Write-Host '=== X / Twitter 视频下载助手 v3 ===' -ForegroundColor Cyan
}

# --- 定位 yt-dlp：便携包优先，其次 PATH，最后本机 winget ---
$binDir = Join-Path $PSScriptRoot 'bin'
if (Test-Path $binDir) { $env:PATH = "$binDir;$env:PATH" }
$yt = Join-Path $binDir 'yt-dlp.exe'
$ytSource = '便携包 bin'
if (-not (Test-Path $yt)) {
    $yt = (Get-Command yt-dlp -ErrorAction SilentlyContinue).Source
    $ytSource = '系统 PATH'
}
if (-not $yt) {
    $yt = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\yt-dlp.exe'
    $ytSource = 'winget 安装'
}
if (-not $yt -or -not (Test-Path $yt)) {
    Write-Host '未找到 yt-dlp.exe。' -ForegroundColor Red
    Write-Host '请把 yt-dlp.exe 放到本脚本同目录的 bin 文件夹，' -ForegroundColor Yellow
    Write-Host '或在本机运行：winget install yt-dlp' -ForegroundColor Yellow
    exit 1
}
Write-Host "yt-dlp: $ytSource"

$hasFfmpeg = (Test-Path (Join-Path $binDir 'ffmpeg.exe')) -or [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
$ffArg = @()
if (Test-Path (Join-Path $binDir 'ffmpeg.exe')) { $ffArg = @('--ffmpeg-location', $binDir) }
if ($hasFfmpeg) {
    Write-Host 'ffmpeg: 已就绪（可合并音视频分离流）'
} else {
    Write-Host 'ffmpeg: 未安装，将优先选择单一 MP4 格式（X 视频通常足够）' -ForegroundColor DarkGray
}

# --- curl.exe（Win10 1803+ / Win11 自带）---
$curlExe = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $curlExe -or $curlExe -notmatch 'system32') { $curlExe = Join-Path $env:WINDIR 'System32\curl.exe' }
if (-not (Test-Path $curlExe)) {
    Write-Host '警告：未找到系统 curl.exe，兜底解析与直链下载可能不可用。' -ForegroundColor Yellow
}

# --- 代理探测 ---
function Test-LocalProxy([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', $port)
        if ($task.Wait(200) -and $client.Connected) { return $true }
    } catch { } finally { $client.Dispose() }
    return $false
}

$proxyUrl = ''
$proxyArg = @()
$proxyHow = ''
if ($NoProxy) {
    $proxyHow = '强制直连'
} else {
    if ($Proxy -and $Proxy -notmatch '(?:x\.com|twitter\.com)/') {
        $proxyUrl = $Proxy.Trim()
        $proxyHow = '命令行 -Proxy 指定'
    }
    # Windows 系统代理优先（最常见的代理软件用法），其次环境变量
    if (-not $proxyUrl) {
        try {
            $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
            if ($inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
                $proxyUrl = $inet.ProxyServer.Trim()
                $proxyHow = 'Windows 系统代理'
            }
        } catch { }
    }
    if (-not $proxyUrl) {
        foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
            $v = [Environment]::GetEnvironmentVariable($name)
            if ($v) { $proxyUrl = $v.Trim(); $proxyHow = "环境变量 $name"; break }
        }
    }
    if (-not $proxyUrl) {
        foreach ($port in @(7897, 7890, 10809, 1080, 2080, 33210)) {
            if (Test-LocalProxy $port) {
                $proxyUrl = "http://127.0.0.1:$port"
                $proxyHow = "本地端口探测 $port"
                break
            }
        }
    }
    if ($proxyUrl -and $proxyUrl -notmatch '^https?://') { $proxyUrl = 'http://' + $proxyUrl }
    if ($proxyUrl) { $proxyArg = @('--proxy', $proxyUrl) }
}
if ($proxyUrl) {
    Write-Host "代理: $proxyUrl（$proxyHow）"
} else {
    Write-Host '网络: 直连（未检测到代理）' -ForegroundColor Yellow
    Write-Host '  注意：在中国大陆直连无法访问 X。请先开启能访问 X 的代理软件，' -ForegroundColor Yellow
    Write-Host '  或用 -Proxy http://127.0.0.1:端口 手动指定。' -ForegroundColor Yellow
}

# --- 登录态：cookies.txt > -Login 的 Chrome cookie ---
$cookieArg = @()
$cookieFile = Join-Path $PSScriptRoot 'cookies.txt'
if ($Login) {
    $cookieArg = @('--cookies-from-browser', 'chrome')
    Write-Host '登录模式：读取 Chrome cookie（若报错请先完全关闭 Chrome）' -ForegroundColor Yellow
} elseif (Test-Path $cookieFile) {
    $cookieArg = @('--cookies', $cookieFile)
    Write-Host "使用同目录 cookies.txt"
}

# --- 网络重试 ---
$netArg = @('--retries', '5', '--extractor-retries', '3', '--socket-timeout', '20')

function Get-TweetId([string]$u) {
    if ($u -match '/status/(\d+)') { return $Matches[1] }
    return ''
}

# --- 公开解析接口兜底：返回最高画质的 MP4 直链 ---
function Get-MirrorLinks([string]$tweetUrl) {
    $tail = $tweetUrl -replace '^https?://(?:www\.)?(?:x\.com|twitter\.com)/?', ''
    $tail = ($tail -replace '[?#].*$', '' -replace '/(?:video|photo)/\d+/?$', '').TrimEnd('/')
    if (-not $tail) { return @() }
    $structured = @()
    $regexed = @()
    foreach ($apiHost in @('api.fxtwitter.com', 'api.vxtwitter.com')) {
        $cargs = @('-s', '--max-time', '20')
        if ($script:proxyUrl) { $cargs += @('-x', $script:proxyUrl) }
        $cargs += "https://$apiHost/$tail"
        $raw = ''
        try { $raw = (& $script:curlExe @cargs) -join "`n" } catch { continue }
        if (-not $raw) { continue }
        try {
            $j = $raw | ConvertFrom-Json
            foreach ($v in @($j.tweet.media.videos)) { if ($v.url -match '^https?://') { $structured += $v.url } }
            foreach ($v in @($j.mediaURLs)) { if ($v -match '^https?://') { $structured += $v } }
            foreach ($v in @($j.media_extended)) { if ($v.type -eq 'video' -and $v.url) { $structured += [string]$v.url } }
        } catch { }
        $clean = $raw -replace '\\/', '/'
        foreach ($m in [regex]::Matches($clean, 'https://video\.twimg\.com/[^"\s,]+?\.mp4(?:\?[^"\s,]*)?')) {
            $regexed += $m.Value
        }
    }
    $pick = @($structured | Where-Object { $_ -is [string] -and $_ -match '^https?://' })
    if ($pick.Count -eq 0) {
        # 正则兜底：按分辨率分组，每组只留最高画质
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
    # 按去掉查询串后的路径去重
    $seen = @{}
    $final = @()
    foreach ($u in $pick) {
        $k = $u -replace '\?.*$', ''
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $final += $u }
    }
    return @($final)
}

# --- 收集推文链接：命令行参数 -> 剪贴板 -> 手动粘贴 ---
if (-not $Urls -or $Urls.Count -eq 0) {
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { }
    if ($clip) {
        if ($Generic) {
            $pattern = 'https?://[^\s"<>]+'
        } else {
            $pattern = 'https?://(?:www\.)?(?:x\.com|twitter\.com)/[^\s"<>]+/status/\d+[^\s"<>]*'
        }
        $Urls = @([regex]::Matches($clip, $pattern) | ForEach-Object { $_.Value })
    }
}
if (-not $Urls -or $Urls.Count -eq 0) {
    if ($Generic) { Write-Host '剪贴板里没找到链接，请直接粘贴：' -ForegroundColor Yellow } else { Write-Host '剪贴板里没找到推文链接，请直接粘贴：' -ForegroundColor Yellow }
    try { $manual = Read-Host '视频 URL' } catch { $manual = '' }
    if ($manual) { $Urls = @($manual.Trim()) }
}
if (-not $Urls -or $Urls.Count -eq 0) {
    Write-Host '没有链接，退出。' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if ($Generic) { Write-Host "共 $($Urls.Count) 个链接" } else { Write-Host "共 $($Urls.Count) 条推文" }
Write-Host ''

$allLinks = @()
foreach ($u0 in $Urls) {
    $isX = $u0 -match '^https?://(?:www\.)?(?:x\.com|twitter\.com)/'
    # X 链接需剥掉 /video/N、/photo/N 与查询串；其它站点必须保留完整 URL（?v=、?p= 等）
    if ($isX) {
        $u = ($u0 -replace '[?#].*$', '' -replace '/(?:video|photo)/\d+/?$', '').TrimEnd('/')
    } else {
        $u = $u0.Trim()
    }
    $tid = Get-TweetId $u
    Write-Host "处理: $u" -ForegroundColor Green

    $links = @()
    $needMirror = $false
    $downloadOk = $false
    if ($OnlyLink) {
        if ($isX) { $linkFmt = 'best[ext=mp4]/best' } else { $linkFmt = 'best' }
        $result = & $yt @proxyArg @cookieArg @netArg -g -f $linkFmt --no-warnings --ignore-errors $u 2>&1
        $links = @($result | Where-Object { $_ -match '^https?://' })
        if ($links.Count -eq 0) { $needMirror = $true }
    } else {
        # 有 ffmpeg 时才允许音视频分离合并；否则强制选单一 MP4，保证零依赖
        if ($hasFfmpeg) { $fmt = 'bv*+ba/b' } else { $fmt = 'best[ext=mp4]/best' }
        & $yt @proxyArg @cookieArg @netArg @ffArg `
            -f $fmt --merge-output-format mp4 `
            --no-overwrites --continue `
            --trim-filenames 80 `
            -o (Join-Path $OutDir '%(id)s_%(uploader)s_%(title)s.%(ext)s') `
            $u
        if ($LASTEXITCODE -ne 0) { $needMirror = $true } else { $downloadOk = $true }
    }

    # 下载模式已由 yt-dlp 完成，直接进入下一条，避免误报「无法解析」
    if ($downloadOk) { continue }

    if ($needMirror -and -not $NoMirror -and $isX) {
        Write-Host '  常规解析失败（内容需要登录），改用公开解析接口取直链...' -ForegroundColor Yellow
        $links = @(Get-MirrorLinks $u)
    }

    if ($links.Count -eq 0) {
        if ($isX) {
            Write-Host '  仍无法解析：检查代理是否可访问 X；或关闭 Chrome 后加 -Login 重试。' -ForegroundColor Red
        } else {
            Write-Host '  该站点未能解析（可能需要登录、有防盗链，或不在 yt-dlp 支持列表）。' -ForegroundColor Red
            Write-Host '  可自查：yt-dlp --simulate --list-formats "链接"；登录内容可在同目录放 cookies.txt。' -ForegroundColor DarkGray
        }
        continue
    }

    $links | ForEach-Object { Write-Host "  $_" }
    $allLinks += $links

    # 下载模式下若走了兜底，直接用 curl 下载直链（支持断点续传）
    if (-not $OnlyLink -and $needMirror) {
        $i = 0
        foreach ($link in $links) {
            $i++
            $leaf = ($link -replace '\?.*$', '') -replace '^.*/', ''
            if ($leaf -notmatch '\.mp4$') { $leaf = "video_$i.mp4" }
            $out = Join-Path $OutDir ("{0}_{1}_{2}" -f $tid, $i, $leaf)
            $cargs = @('-L', '-#', '--retry', '5', '--retry-delay', '2', '--connect-timeout', '20', '-C', '-', '-o', $out)
            if ($proxyUrl) { $cargs += @('-x', $proxyUrl) }
            $cargs += $link
            & $script:curlExe @cargs
        }
    }
}

if ($OnlyLink -and $allLinks.Count -gt 0) {
    try {
        Set-Clipboard -Value ($allLinks -join "`n")
        Write-Host "`n共 $($allLinks.Count) 条直链已复制。到 FDM 点「+ 新建下载」按 Ctrl+V 即可（多条可用 FDM 批量添加）。" -ForegroundColor Cyan
    } catch {
        Write-Host "`n请手动复制上面的直链。" -ForegroundColor Yellow
    }
}

Write-Host "`n完成。下载目录: $OutDir" -ForegroundColor Cyan
