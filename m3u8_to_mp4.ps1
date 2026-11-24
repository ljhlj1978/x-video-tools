<#
  m3u8 -> mp4 转换工具 v1
  用法一：把 .m3u8 文件拖到「m3u8转mp4.bat」图标上（可多个）
  用法二：双击 bat，从剪贴板取路径 / URL；剪贴板为空时手动粘贴
  用法三：命令行 powershell -ExecutionPolicy Bypass -File m3u8_to_mp4.ps1 "路径或URL"

  输入：本地 .m3u8 文件，或 http(s) 开头的 m3u8 地址
  输出：本地文件 → 同目录同名 .mp4；网络 URL → 下载\视频下载
  依赖：同目录 bin\ffmpeg.exe（便携包已附带），或系统 PATH 里的 ffmpeg
  参数：-Recode 强制重编码（兼容性最好，但慢）

  默认先做「-c copy」无损封装；失败自动重试 aac_adtstoasc，再失败自动转重编码。
  注意：ffmpeg 只会按 m3u8 里写明的地址取分片，分片与密钥必须能直接访问。
#>
param(
    [switch]$Recode,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Inputs
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host '=== m3u8 -> mp4 转换工具 v1 ===' -ForegroundColor Cyan

# --- 定位 ffmpeg（便携包优先）---
$binDir = Join-Path $PSScriptRoot 'bin'
if (Test-Path $binDir) { $env:PATH = "$binDir;$env:PATH" }
$ff = Join-Path $binDir 'ffmpeg.exe'
if (-not (Test-Path $ff)) { $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source }
if (-not $ff -or -not (Test-Path $ff)) {
    Write-Host '未找到 ffmpeg.exe。请把 ffmpeg.exe 放到本脚本同目录的 bin 文件夹。' -ForegroundColor Red
    exit 1
}
Write-Host "ffmpeg: $ff"

# --- 让 ffmpeg 走 Windows 系统代理（网络 m3u8 用得上）---
try {
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if ($inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
        $p = $inet.ProxyServer.Trim()
        if ($p -notmatch '^https?://') { $p = 'http://' + $p }
        $env:http_proxy = $p; $env:HTTP_PROXY = $p
        $env:https_proxy = $p; $env:HTTPS_PROXY = $p
        Write-Host "代理: $p（Windows 系统代理）"
    }
} catch { }

# --- 收集输入：参数 -> 剪贴板 -> 手动粘贴 ---
if (-not $Inputs -or $Inputs.Count -eq 0) {
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { }
    if ($clip) {
        $Inputs = @($clip -split "[\r\n]+" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    }
}
if (-not $Inputs -or $Inputs.Count -eq 0) {
    Write-Host '请输入 m3u8 文件路径或 URL：' -ForegroundColor Yellow
    try { $manual = Read-Host '路径 / URL' } catch { $manual = '' }
    if ($manual) { $Inputs = @($manual.Trim()) }
}
if (-not $Inputs -or $Inputs.Count -eq 0) {
    Write-Host '没有输入，退出。' -ForegroundColor Red
    exit 1
}

$defaultOutDir = Join-Path $env:USERPROFILE 'Downloads\视频下载'
Write-Host "共 $($Inputs.Count) 个输入`n"

function Get-FreePath([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $path }
    $dir = Split-Path $path -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    $ext = [IO.Path]::GetExtension($path)
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext))) { $i++ }
    return (Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext))
}

$results = @()
foreach ($raw in $Inputs) {
    $item = $raw.Trim().Trim('"')
    if (-not $item) { continue }
    $isUrl = $item -match '^https?://'

    # 一律用 LiteralPath：文件名里的 [ ] ( ) 等字符不能被当成通配符
    if (-not $isUrl -and (Test-Path -LiteralPath $item -PathType Container)) {
        # 拖进来的可能是文件夹（迅雷等下载器常把任务存成同名目录），自动找里面的 m3u8
        $cands = @(Get-ChildItem -LiteralPath $item -File -Filter '*.m3u8' | Sort-Object Name)
        if ($cands.Count -eq 0) {
            $cands = @(Get-ChildItem -LiteralPath $item -File -Recurse -Depth 2 -Filter '*.m3u8' | Select-Object -First 5)
        }
        if ($cands.Count -eq 1) {
            Write-Host "  这是文件夹，自动使用其中的 $($cands[0].Name)" -ForegroundColor DarkGray
            $item = $cands[0].FullName
        } elseif ($cands.Count -gt 1) {
            Write-Host "  这是文件夹，里面有 $($cands.Count) 个 m3u8，请把具体文件拖到图标上：" -ForegroundColor Yellow
            $cands | ForEach-Object { Write-Host "    $($_.FullName)" }
            continue
        } else {
            Write-Host "跳过（文件夹里没有 .m3u8 文件）: $item" -ForegroundColor Yellow
            continue
        }
    }
    if (-not $isUrl -and -not (Test-Path -LiteralPath $item -PathType Leaf)) {
        Write-Host "跳过（文件不存在）: $item" -ForegroundColor Yellow
        continue
    }

    if ($isUrl) {
        if (-not (Test-Path $defaultOutDir)) { New-Item -ItemType Directory -Path $defaultOutDir -Force | Out-Null }
        $leaf = ($item -replace '[?#].*$', '') -replace '^.*/', ''
        $leaf = [IO.Path]::GetFileNameWithoutExtension($leaf)
        if (-not $leaf) { $leaf = 'm3u8_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
        $out = Join-Path $defaultOutDir ($leaf + '.mp4')
    } else {
        $full = (Resolve-Path -LiteralPath $item).Path
        $out = [IO.Path]::ChangeExtension($full, '.mp4')
    }
    $out = Get-FreePath $out

    Write-Host "输入: $item" -ForegroundColor Green
    Write-Host "输出: $out"

    if ($Recode) {
        $modes = @(@{ Name = '重编码'; Args = @('-c:v', 'libx264', '-c:a', 'aac') })
    } else {
        $modes = @(
            @{ Name = '无损封装 copy'; Args = @('-c', 'copy') }
            @{ Name = '无损封装 + aac_adtstoasc'; Args = @('-c', 'copy', '-bsf:a', 'aac_adtstoasc') }
            @{ Name = '重编码兜底'; Args = @('-c:v', 'libx264', '-c:a', 'aac') }
        )
    }

    $ok = $false
    foreach ($mode in $modes) {
        $modeName = $mode.Name
        $ffArgs = $mode.Args
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
        Write-Host "  尝试：$modeName ..." -ForegroundColor DarkGray
        $callArgs = @('-hide_banner', '-loglevel', 'warning', '-nostats', '-nostdin', '-y', '-i', $item) + $ffArgs + @($out)
        & $ff @callArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 0) {
            Write-Host "  完成（$modeName），$((Get-Item -LiteralPath $out).Length) 字节" -ForegroundColor Cyan
            $ok = $true
            $results += $out
            break
        }
    }
    if (-not $ok) {
        Write-Host '  转换失败：检查分片地址、密钥是否可访问，以及 m3u8 列表是否完整。' -ForegroundColor Red
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    }
    Write-Host ''
}

if ($results.Count -gt 0) {
    Write-Host "完成，共成功 $($results.Count) 个：" -ForegroundColor Cyan
    $results | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '没有成功转换的文件。' -ForegroundColor Yellow
}
