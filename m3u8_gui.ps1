<#
  m3u8 -> mp4 批量转换工具（窗口版 v3 · 系统托盘常驻）

  双击「m3u8批量转换.bat」打开窗口：
    · 拖 .m3u8 文件 / 整个文件夹到列表里（文件夹会递归收集所有 .m3u8）
    · 或用「添加文件 / 添加文件夹 / 添加网址」按钮
    · 一键批量转换，界面显示每项状态、总进度、日志，可随时停止
    · 点右上角 × 不退出：窗口收进系统托盘，转换在后台继续；
      双击托盘图标恢复窗口，右键「退出程序」或窗口里的「退出程序」才真正结束

  高级 / 自测：命令行无界面批量模式
    powershell -ExecutionPolicy Bypass -File m3u8_gui.ps1 -Headless "D:\目录" "xx.m3u8"
    可选 -Recode 强制重编码，-OutDir "D:\输出" 统一输出目录
    -SmokeTest 只构建窗口不进入消息循环（自检用，不弹窗）

  依赖：同目录 bin\ffmpeg.exe，或桌面「X视频下载-便携版\bin\ffmpeg.exe」，或系统 PATH 里的 ffmpeg
  注意：ffmpeg 只按 m3u8 里写明的地址取分片，分片与密钥必须能直接访问。
#>
param(
    [Parameter()][switch]$Headless,
    [Parameter()][switch]$SmokeTest,
    [Parameter()][switch]$Recode,
    [Parameter()][string]$OutDir,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Inputs
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$script:guiMode = -not $Headless
$script:cancel = $false
$script:busy = $false
$script:ff = $null
$script:defaultOutDir = Join-Path $env:USERPROFILE 'Downloads\视频下载'
# 托盘常驻状态：reallyExit 放行 FormClosing；exitPending 等批量循环收尾后再退出，
# 避免正在跑的 ffmpeg 子进程变成孤儿。
$script:reallyExit    = $false
$script:exitPending   = $false
$script:trayHintShown = $false

# ---------- ffmpeg 定位 ----------
function Find-Ffmpeg {
    $cands = @(
        (Join-Path $PSScriptRoot 'bin\ffmpeg.exe'),
        (Join-Path $PSScriptRoot 'X视频下载-便携版\bin\ffmpeg.exe')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    return $null
}
$script:ff = Find-Ffmpeg

# ---------- 网络 m3u8：代理 + 修复宿主环境变量大小写重名 ----------
# Windows 环境变量名不区分大小写。若进程里同时有 HTTPS_PROXY 与 https_proxy
# （宿主常注入），Start-Process 复制环境块时会抛「Item has already been added」，
# 子进程根本起不来。这里无条件清理所有变体，再只写小写一份。
try {
    $injected = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
    if (-not $injected) { $injected = [Environment]::GetEnvironmentVariable('https_proxy') }
    foreach ($n in @('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY')) {
        try { [Environment]::SetEnvironmentVariable($n, $null, 'Process') } catch { }
    }
    $p = ''
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($inet -and $inet.ProxyEnable -eq 1 -and $inet.ProxyServer) {
        $p = $inet.ProxyServer.Trim()
    } elseif ($injected) {
        $p = $injected.Trim()
    }
    if ($p) {
        if ($p -notmatch '^https?://') { $p = 'http://' + $p }
        [Environment]::SetEnvironmentVariable('http_proxy', $p, 'Process')
        [Environment]::SetEnvironmentVariable('https_proxy', $p, 'Process')
        $script:proxyText = $p
    }
} catch { }
if (-not $script:proxyText) { $script:proxyText = '直连' }

# ---------- 工具函数 ----------
function Get-FreePath([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $path }
    $dir = Split-Path $path -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($path)
    $ext = [IO.Path]::GetExtension($path)
    $i = 2
    while (Test-Path -LiteralPath (Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext))) { $i++ }
    return (Join-Path $dir ("{0}_{1}{2}" -f $base, $i, $ext))
}

function Expand-Source([string]$raw) {
    $s = $raw.Trim().Trim('"')
    if (-not $s) { return @() }
    if ($s -match '^https?://') { return @($s) }
    if (Test-Path -LiteralPath $s -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $s -File -Recurse -Filter '*.m3u8' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -ieq '.m3u8' } | Sort-Object FullName |
                   ForEach-Object { $_.FullName })
        return $files
    }
    if (Test-Path -LiteralPath $s -PathType Leaf) { return @((Resolve-Path -LiteralPath $s).Path) }
    return @()
}

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

# 单条 ffmpeg 调用：Start-Process + 错误日志文件 + 可取消等待（界面不假死）
function Invoke-FfmpegOnce {
    param([string]$Src, [string]$Out, [string[]]$ModeArgs)

    $errFile = Join-Path $env:TEMP ('m3u8gui_' + [guid]::NewGuid().ToString('N') + '.log')
    $callArgs = @('-hide_banner', '-loglevel', 'warning', '-nostats', '-nostdin', '-y', '-i', $Src) + $ModeArgs + @($Out)
    $quoted = @($callArgs | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' })

    $proc = $null
    $errText = ''
    $exit = -1
    try {
        $proc = Start-Process -FilePath $script:ff -ArgumentList $quoted -PassThru `
                    -NoNewWindow -RedirectStandardError $errFile -ErrorAction Stop
        while ($true) {
            if ($proc.WaitForExit(150)) { break }
            if ($script:guiMode) { [System.Windows.Forms.Application]::DoEvents() }
            if ($script:cancel) {
                try { $proc.Kill() } catch { }
                $proc.WaitForExit(2000) | Out-Null
                break
            }
        }
        try { $proc.WaitForExit() } catch { }
        try { $exit = $proc.ExitCode } catch { }
    } catch {
        $errText = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $errFile) {
        try {
            $all = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
            $tail = [string](($all | Where-Object { $_ } | Select-Object -Last 6) -join ' | ')
            if ($tail.Trim()) { $errText = $tail.Trim() }
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    return @{ Exit = $exit; Error = $errText; Cancelled = $script:cancel }
}

# ---------- 批量转换引擎（窗口 / 命令行共用） ----------
function Invoke-Batch {
    param([string[]]$Sources, [object[]]$Items, [string]$OutDir, [bool]$ForceRecode)

    $okCount = 0; $failCount = 0; $outs = @()
    $total = @($Sources).Count
    if ($total -eq 0) { return @{ Ok = 0; Fail = 0; Outs = @() } }

    if ($script:guiMode) {
        $script:progress.Maximum = $total
        $script:progress.Value = 0
        $script:btnStart.Enabled = $false
        $script:btnStop.Enabled = $true
        $script:btnAddFile.Enabled = $false
        $script:btnAddFolder.Enabled = $false
        $script:btnAddUrl.Enabled = $false
        $script:btnRemove.Enabled = $false
        $script:btnClear.Enabled = $false
    }
    $script:busy = $true
    $script:cancel = $false
    Add-Log "开始批量转换，共 $total 项。"

    for ($i = 0; $i -lt $total; $i++) {
        if ($script:cancel) { Add-Log '已停止，跳过剩余任务。'; break }
        $src = $Sources[$i]
        $lvi = $null
        if ($Items -and $Items.Count -gt $i) { $lvi = $Items[$i] }
        $short = if ($src.Length -gt 70) { $src.Substring(0, 70) + '…' } else { $src }

        if ($script:guiMode) {
            $script:lblStatus.Text = "正在处理 ($($i + 1)/$total)：$short"
            $script:progress.Value = $i
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($lvi) { $lvi.SubItems[0].Text = '转换中…'; $lvi.SubItems[3].Text = '' }
        Add-Log "[$($i + 1)/$total] $src"

        $isUrl = $src -match '^https?://'
        if ($isUrl) {
            $baseDir = if ($OutDir) { $OutDir } else { $script:defaultOutDir }
            $leaf = ($src -replace '[?#].*$', '') -replace '^.*/', ''
            $leaf = [IO.Path]::GetFileNameWithoutExtension($leaf)
            if (-not $leaf) { $leaf = 'm3u8_' + (Get-Date -Format 'yyyyMMdd_HHmmss') }
        } else {
            $baseDir = if ($OutDir) { $OutDir } else { (Split-Path $src -Parent) }
            $leaf = [IO.Path]::GetFileNameWithoutExtension($src)
        }
        try { [System.IO.Directory]::CreateDirectory($baseDir) | Out-Null } catch { }
        $out = Get-FreePath (Join-Path $baseDir ($leaf + '.mp4'))

        if ($ForceRecode) {
            $modes = @(@{ Name = '重编码'; Args = @('-c:v', 'libx264', '-c:a', 'aac') })
        } else {
            $modes = @(
                @{ Name = '无损封装 copy'; Args = @('-c', 'copy') }
                @{ Name = '无损封装 + aac_adtstoasc'; Args = @('-c', 'copy', '-bsf:a', 'aac_adtstoasc') }
                @{ Name = '重编码兜底'; Args = @('-c:v', 'libx264', '-c:a', 'aac') }
            )
        }

        $ok = $false; $usedMode = ''; $lastErr = ''
        foreach ($mode in $modes) {
            if ($script:cancel) { break }
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
            Add-Log "  尝试：$($mode.Name)"
            $r = Invoke-FfmpegOnce -Src $src -Out $out -ModeArgs $mode.Args
            if ($r.Cancelled) { break }
            if ($r.Error) { $lastErr = $r.Error }
            # PowerShell 5.1 的 Start-Process -PassThru 读不到 ExitCode（恒为空），
            # 因此以「产物有效 + stderr 无致命错误」作为成功判据。
            $sizeOk = $false
            if (Test-Path -LiteralPath $out) {
                try { $sizeOk = ((Get-Item -LiteralPath $out).Length -gt 0) } catch { }
            }
            $fatal = ([string]$r.Error) -match '(?i)\berror\b|\bfailed\b|\bunable\b|invalid data|no such file|not found'
            if ($sizeOk -and ($r.Exit -eq 0 -or -not $fatal)) {
                $ok = $true; $usedMode = $mode.Name; break
            }
        }

        if ($script:cancel) {
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
            if ($lvi) { $lvi.SubItems[0].Text = '已停止'; $lvi.SubItems[3].Text = '' }
            break
        }

        if ($ok) {
            $size = (Get-Item -LiteralPath $out).Length
            $okCount++; $outs += $out
            if ($lvi) { $lvi.SubItems[0].Text = '✓ 成功'; $lvi.SubItems[3].Text = "$usedMode · $([math]::Round($size / 1MB, 1)) MB" }
            Add-Log "  ✓ 成功（$usedMode）→ $out"
        } else {
            $failCount++
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
            if ($lvi) { $lvi.SubItems[0].Text = '✗ 失败'; $lvi.SubItems[3].Text = '见日志' }
            Add-Log '  ✗ 失败：分片 / 密钥不可访问、列表不完整或格式不支持。'
            if ($lastErr) { Add-Log "  ffmpeg: $lastErr" }
        }
        if ($script:guiMode) {
            $script:progress.Value = $i + 1
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    if ($script:guiMode) {
        $script:lblStatus.Text = "完成：成功 $okCount 项，失败 $failCount 项。"
        $script:progress.Value = $script:progress.Maximum
        $script:btnStart.Enabled = $true
        $script:btnStop.Enabled = $false
        $script:btnAddFile.Enabled = $true
        $script:btnAddFolder.Enabled = $true
        $script:btnAddUrl.Enabled = $true
        $script:btnRemove.Enabled = $true
        $script:btnClear.Enabled = $true
    }
    $script:busy = $false
    $script:cancel = $false
    Add-Log "批量结束：成功 $okCount，失败 $failCount。"
    # 托盘菜单里请求了「退出」且当时正在转换：这里子进程已收尾，才真正退出
    if ($script:exitPending) { Complete-AppExit }
    return @{ Ok = $okCount; Fail = $failCount; Outs = $outs }
}

# ---------- 无界面批量模式 ----------
if ($Headless) {
    if (-not $script:ff) { Write-Host 'ERROR: 未找到 ffmpeg.exe' -ForegroundColor Red; exit 1 }
    Write-Host "ffmpeg: $script:ff"
    Write-Host "代理: $($script:proxyText)"
    $sources = @()
    foreach ($raw in @($Inputs)) { $sources += @(Expand-Source $raw) }
    $sources = @($sources | Select-Object -Unique)
    if ($sources.Count -eq 0) { Write-Host 'ERROR: 没有可用的 m3u8 输入' -ForegroundColor Red; exit 1 }
    Write-Host "共 $($sources.Count) 项待转换"
    $r = Invoke-Batch -Sources $sources -Items $null -OutDir $OutDir -ForceRecode ([bool]$Recode)
    foreach ($o in $r.Outs) { Write-Host "OUT: $o" }
    if ($r.Fail -gt 0 -and $r.Ok -eq 0) { exit 1 }
    exit 0
}

# ---------- 窗口界面 ----------
[System.Windows.Forms.Application]::EnableVisualStyles()
$font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'm3u8 批量转 mp4'
$script:form.Size = New-Object System.Drawing.Size(900, 680)
$script:form.MinimumSize = New-Object System.Drawing.Size(760, 580)
$script:form.StartPosition = 'CenterScreen'
$script:form.Font = $font
$script:form.ShowInTaskbar = $true

$lblTip = New-Object System.Windows.Forms.Label
$lblTip.Text = '把 .m3u8 文件或整个文件夹拖到下面（自动收集所有 m3u8），也可用按钮添加；点「开始批量转换」依次处理。点 × 收进托盘后台继续。'
$lblTip.Location = New-Object System.Drawing.Point(16, 12)
$lblTip.Size = New-Object System.Drawing.Size(860, 24)
$script:form.Controls.Add($lblTip)

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.Location = New-Object System.Drawing.Point(16, 40)
$script:lv.Size = New-Object System.Drawing.Size(852, 250)
$script:lv.View = 'Details'
$script:lv.FullRowSelect = $true
$script:lv.GridLines = $true
$script:lv.AllowDrop = $true
$script:lv.MultiSelect = $true
$script:lv.Columns.Add('状态', 90) | Out-Null
$script:lv.Columns.Add('文件', 220) | Out-Null
$script:lv.Columns.Add('所在目录 / 网址', 390) | Out-Null
$script:lv.Columns.Add('结果', 135) | Out-Null
$script:form.Controls.Add($script:lv)

function Add-TaskPath([string]$raw) {
    $found = @(Expand-Source $raw)
    $added = 0
    foreach ($p in $found) {
        $exists = @($script:lv.Items | ForEach-Object { $_.Tag })
        if ($exists -contains $p) { continue }
        $isUrl = $p -match '^https?://'
        $name = if ($isUrl) { (($p -split '[?#]')[0] -split '/')[-1] } else { [IO.Path]::GetFileName($p) }
        $dir = if ($isUrl) { $p } else { Split-Path $p -Parent }
        $lvi = New-Object System.Windows.Forms.ListViewItem('等待')
        $lvi.SubItems.Add($name) | Out-Null
        $lvi.SubItems.Add($dir) | Out-Null
        $lvi.SubItems.Add('') | Out-Null
        $lvi.Tag = $p
        $script:lv.Items.Add($lvi) | Out-Null
        $added++
    }
    return @{ Added = $added; Found = $found.Count }
}

$script:btnAddFile = New-Object System.Windows.Forms.Button
$script:btnAddFile.Text = '添加文件…'
$script:btnAddFile.Location = New-Object System.Drawing.Point(16, 300)
$script:btnAddFile.Size = New-Object System.Drawing.Size(110, 30)
$script:form.Controls.Add($script:btnAddFile)

$script:btnAddFolder = New-Object System.Windows.Forms.Button
$script:btnAddFolder.Text = '添加文件夹…'
$script:btnAddFolder.Location = New-Object System.Drawing.Point(132, 300)
$script:btnAddFolder.Size = New-Object System.Drawing.Size(120, 30)
$script:form.Controls.Add($script:btnAddFolder)

$script:btnAddUrl = New-Object System.Windows.Forms.Button
$script:btnAddUrl.Text = '添加网址…'
$script:btnAddUrl.Location = New-Object System.Drawing.Point(258, 300)
$script:btnAddUrl.Size = New-Object System.Drawing.Size(110, 30)
$script:form.Controls.Add($script:btnAddUrl)

$script:btnRemove = New-Object System.Windows.Forms.Button
$script:btnRemove.Text = '移除选中'
$script:btnRemove.Location = New-Object System.Drawing.Point(374, 300)
$script:btnRemove.Size = New-Object System.Drawing.Size(100, 30)
$script:form.Controls.Add($script:btnRemove)

$script:btnClear = New-Object System.Windows.Forms.Button
$script:btnClear.Text = '清空列表'
$script:btnClear.Location = New-Object System.Drawing.Point(480, 300)
$script:btnClear.Size = New-Object System.Drawing.Size(90, 30)
$script:form.Controls.Add($script:btnClear)

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Text = '待转换：0 项'
$lblCount.Location = New-Object System.Drawing.Point(590, 306)
$lblCount.Size = New-Object System.Drawing.Size(270, 22)
$script:form.Controls.Add($lblCount)
$script:lblCount = $lblCount

function Update-Count {
    $n = $script:lv.Items.Count
    $script:lblCount.Text = "待转换：$n 项"
    $script:btnStart.Text = "开始批量转换 ($n)"
    $script:btnStart.Enabled = ($n -gt 0 -and [bool]$script:ff)
}

$script:chkOut = New-Object System.Windows.Forms.CheckBox
$script:chkOut.Text = '统一输出到：'
$script:chkOut.Location = New-Object System.Drawing.Point(16, 344)
$script:chkOut.Size = New-Object System.Drawing.Size(115, 26)
$script:form.Controls.Add($script:chkOut)

$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = New-Object System.Drawing.Point(132, 344)
$txtOut.Size = New-Object System.Drawing.Size(640, 26)
$txtOut.Text = $script:defaultOutDir
$txtOut.Enabled = $false
$script:form.Controls.Add($txtOut)
$script:txtOut = $txtOut

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览…'
$btnBrowse.Location = New-Object System.Drawing.Point(780, 343)
$btnBrowse.Size = New-Object System.Drawing.Size(88, 28)
$btnBrowse.Enabled = $false
$script:form.Controls.Add($btnBrowse)
$script:btnBrowse = $btnBrowse

$chkRecode = New-Object System.Windows.Forms.CheckBox
$chkRecode.Text = '强制重编码（最慢，但兼容性最好；默认优先无损封装）'
$chkRecode.Location = New-Object System.Drawing.Point(16, 376)
$chkRecode.Size = New-Object System.Drawing.Size(500, 26)
$script:form.Controls.Add($chkRecode)
$script:chkRecode = $chkRecode

$chkOpen = New-Object System.Windows.Forms.CheckBox
$chkOpen.Text = '完成后打开输出文件夹'
$chkOpen.Location = New-Object System.Drawing.Point(530, 376)
$chkOpen.Size = New-Object System.Drawing.Size(220, 26)
$chkOpen.Checked = $true
$script:form.Controls.Add($chkOpen)
$script:chkOpen = $chkOpen

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = if ($script:ff) { '就绪。' } else { '未找到 ffmpeg.exe —— 请把便携包 bin 文件夹放在本脚本旁边。' }
$script:lblStatus.Location = New-Object System.Drawing.Point(16, 408)
$script:lblStatus.Size = New-Object System.Drawing.Size(852, 22)
$script:form.Controls.Add($script:lblStatus)

$script:progress = New-Object System.Windows.Forms.ProgressBar
$script:progress.Location = New-Object System.Drawing.Point(16, 432)
$script:progress.Size = New-Object System.Drawing.Size(852, 18)
$script:progress.Minimum = 0
$script:progress.Maximum = 100
$script:form.Controls.Add($script:progress)

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = '运行日志'
$lblLogTitle.Location = New-Object System.Drawing.Point(16, 456)
$lblLogTitle.Size = New-Object System.Drawing.Size(200, 20)
$script:form.Controls.Add($lblLogTitle)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(16, 478)
$script:txtLog.Size = New-Object System.Drawing.Size(852, 108)
$script:txtLog.Multiline = $true
$script:txtLog.ReadOnly = $true
$script:txtLog.ScrollBars = 'Vertical'
$script:txtLog.WordWrap = $false
$script:txtLog.BackColor = [System.Drawing.Color]::White
$script:form.Controls.Add($script:txtLog)

$script:btnStart = New-Object System.Windows.Forms.Button
$script:btnStart.Text = '开始批量转换 (0)'
$script:btnStart.Location = New-Object System.Drawing.Point(16, 598)
$script:btnStart.Size = New-Object System.Drawing.Size(180, 36)
$script:form.Controls.Add($script:btnStart)

$script:btnStop = New-Object System.Windows.Forms.Button
$script:btnStop.Text = '停止'
$script:btnStop.Location = New-Object System.Drawing.Point(204, 598)
$script:btnStop.Size = New-Object System.Drawing.Size(90, 36)
$script:btnStop.Enabled = $false
$script:form.Controls.Add($script:btnStop)

$btnOpenOut = New-Object System.Windows.Forms.Button
$btnOpenOut.Text = '打开输出目录'
$btnOpenOut.Location = New-Object System.Drawing.Point(302, 598)
$btnOpenOut.Size = New-Object System.Drawing.Size(120, 36)
$script:form.Controls.Add($btnOpenOut)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '退出程序'
$btnClose.Location = New-Object System.Drawing.Point(778, 598)
$btnClose.Size = New-Object System.Drawing.Size(90, 36)
$script:form.Controls.Add($btnClose)

$lblFoot = New-Object System.Windows.Forms.Label
$lblFoot.Text = "ffmpeg: $(if ($script:ff) { $script:ff } else { '未找到' })    |    代理: $($script:proxyText)"
$lblFoot.Location = New-Object System.Drawing.Point(16, 640)
$lblFoot.Size = New-Object System.Drawing.Size(852, 20)
$lblFoot.ForeColor = [System.Drawing.Color]::Gray
$script:form.Controls.Add($lblFoot)

# ---------- 系统托盘 ----------
# 点右上角 × 只隐藏窗口，进程和转换任务继续在后台跑。
function New-TrayIcon {
    try {
        $bmp = [System.Drawing.Bitmap]::new(32, 32)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $bg = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(34, 153, 110))
        $wh = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        $g.FillEllipse($bg, 1, 1, 30, 30)
        [System.Drawing.Point[]]$tri = @(
            [System.Drawing.Point]::new(12, 9),
            [System.Drawing.Point]::new(12, 23),
            [System.Drawing.Point]::new(24, 16)
        )
        $g.FillPolygon($wh, $tri)                     # 白色播放三角
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
            '正在转换，确定要停止并退出吗？当前任务会被中止，已完成的文件保留。',
            '确认退出', 'OKCancel', 'Question')
        if ($r -ne 'OK') { return }
        # 不立刻结束进程：先让批量循环把 ffmpeg 子进程收尾，再由它真正退出
        $script:exitPending = $true
        $script:cancel = $true
        Add-Log '已请求退出，当前任务结束后程序会自动关闭。'
        return
    }
    Complete-AppExit
}

$script:tray = New-Object System.Windows.Forms.NotifyIcon
try { $script:tray.Icon = New-TrayIcon } catch { $script:tray.Icon = [System.Drawing.SystemIcons]::Application }
$script:tray.Text = 'm3u8 批量转 mp4'
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

# ---------- 事件 ----------
$script:lv.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) -or
        $e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::Text)) {
        $e.Effect = 'Copy'
    }
})
$script:lv.Add_DragDrop({
    param($sender, $e)
    $added = 0; $none = 0
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        foreach ($p in $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)) {
            $r = Add-TaskPath $p
            $added += $r.Added
            if ($r.Found -eq 0) { $none++ }
        }
    } else {
        $txt = [string]$e.Data.GetData([System.Windows.Forms.DataFormats]::Text)
        foreach ($line in ($txt -split "[\r\n]+")) {
            if ($line.Trim() -match '^https?://') { $r = Add-TaskPath $line.Trim(); $added += $r.Added }
        }
    }
    Update-Count
    $msg = "拖放添加 $added 项"
    if ($none -gt 0) { $msg += "，$none 个文件夹里没找到 m3u8" }
    Add-Log $msg
})

$script:btnAddFile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = 'm3u8 播放列表|*.m3u8|所有文件|*.*'
    $dlg.Title = '选择 m3u8 文件（可多选）'
    if ($dlg.ShowDialog() -eq 'OK') {
        foreach ($f in $dlg.FileNames) { Add-TaskPath $f | Out-Null }
        Update-Count
        Add-Log "添加文件，共 $($dlg.FileNames.Count) 个。"
    }
})
$script:btnAddFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择文件夹（会递归收集里面所有 .m3u8）'
    $dlg.ShowNewFolderButton = $false
    if ($dlg.ShowDialog() -eq 'OK') {
        $r = Add-TaskPath $dlg.SelectedPath
        Update-Count
        Add-Log "添加文件夹：$($dlg.SelectedPath) → 找到 $($r.Found) 个 m3u8，新增 $($r.Added) 项。"
    }
})
$script:btnAddUrl.Add_Click({
    $clip = ''
    try { $clip = [string](Get-Clipboard -Raw) } catch { }
    $default = ''
    if ($clip -match '^https?://') { $default = $clip.Trim() }
    $u = [Microsoft.VisualBasic.Interaction]::InputBox('输入 m3u8 网址（http/https 开头）：', '添加网址', $default)
    if ($u -and $u.Trim()) {
        $r = Add-TaskPath $u.Trim()
        Update-Count
        Add-Log "添加网址：$($u.Trim())"
    }
})
$script:btnRemove.Add_Click({
    foreach ($it in @($script:lv.SelectedItems)) { $script:lv.Items.Remove($it) }
    Update-Count
})
$script:btnClear.Add_Click({
    $script:lv.Items.Clear()
    Update-Count
    Add-Log '已清空列表。'
})
$script:chkOut.Add_CheckedChanged({
    $script:txtOut.Enabled = $script:chkOut.Checked
    $script:btnBrowse.Enabled = $script:chkOut.Checked
})
$script:chkOut.Checked = $false
$script:btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择统一的 MP4 输出文件夹'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq 'OK') { $script:txtOut.Text = $dlg.SelectedPath }
})
$script:btnStart.Add_Click({
    $n = $script:lv.Items.Count
    if ($n -eq 0) { return }
    if (-not $script:ff) {
        [System.Windows.Forms.MessageBox]::Show('未找到 ffmpeg.exe。请把便携包里的 bin 文件夹复制到本脚本旁边。', '缺少组件', 'OK', 'Error') | Out-Null
        return
    }
    if ($script:chkOut.Checked) {
        $d = $script:txtOut.Text.Trim()
        if (-not $d) { [System.Windows.Forms.MessageBox]::Show('请先选择统一输出文件夹。', '提示', 'OK', 'Warning') | Out-Null; return }
        try { [System.IO.Directory]::CreateDirectory($d) | Out-Null } catch { }
    }
    foreach ($it in @($script:lv.Items)) { $it.SubItems[0].Text = '等待'; $it.SubItems[3].Text = '' }
    $sources = @($script:lv.Items | ForEach-Object { $_.Tag })
    $items = @($script:lv.Items)
    $outDir = if ($script:chkOut.Checked) { $script:txtOut.Text.Trim() } else { '' }
    $r = Invoke-Batch -Sources $sources -Items $items -OutDir $outDir -ForceRecode ([bool]$script:chkRecode.Checked)
    if ($script:chkOpen.Checked -and $r.Ok -gt 0 -and -not $script:reallyExit) {
        $first = $r.Outs[0]
        try { Start-Process explorer.exe -ArgumentList ('/select,"' + $first + '"') } catch { }
    }
    $doneText = "批量转换完成：成功 $($r.Ok) 项，失败 $($r.Fail) 项。详情见运行日志。"
    if ($script:form.Visible -and -not $script:reallyExit) {
        [System.Windows.Forms.MessageBox]::Show($doneText, '完成', 'OK', 'Information') | Out-Null
    } elseif (-not $script:reallyExit) {
        # 窗口收在托盘时，用气泡通知代替会突然弹出的对话框
        try { $script:tray.ShowBalloonTip(5000, '批量转换完成', $doneText, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
})
$script:btnStop.Add_Click({
    $script:cancel = $true
    $script:lblStatus.Text = '正在停止…'
    Add-Log '收到停止请求，当前任务结束后中止。'
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
                $script:tray.ShowBalloonTip(4000, 'm3u8 批量转 mp4',
                    '点 × 不会退出，转换在后台继续。双击图标恢复窗口，右键可退出程序。',
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

# 预加载：把文件拖到 bat 图标上启动时，自动加入列表
if ($Inputs -and $Inputs.Count -gt 0) {
    foreach ($raw in $Inputs) { Add-TaskPath $raw | Out-Null }
}
Update-Count
Add-Log "就绪。ffmpeg: $(if ($script:ff) { $script:ff } else { '未找到' })；代理: $($script:proxyText)"

# 构建自检：把窗体、控件、事件、任务列表全部构造一遍但不进入消息循环。
# 供排查 / 自动化验证使用，普通双击不会走到这里。
if ($SmokeTest) {
    Write-Host "GUI-BUILD-OK title=$($script:form.Text) controls=$($script:form.Controls.Count) tasks=$($script:lv.Items.Count) startBtn=$($script:btnStart.Text) ffmpeg=$(if ($script:ff) { 'yes' } else { 'no' }) tray=$(if ($script:tray.Icon) { 'yes' } else { 'no' }) trayItems=$($script:trayMenu.Items.Count)"
    if ($script:lv.Items.Count -gt 0) { Write-Host "  firstTask=$($script:lv.Items[0].Tag)" }
    try { $script:tray.Dispose() } catch { }
    exit 0
}

try {
    [System.Windows.Forms.Application]::Run($script:form)
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '窗口运行出错', 'OK', 'Error') | Out-Null
}
