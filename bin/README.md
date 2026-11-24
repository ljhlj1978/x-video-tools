# bin 目录

把下面两个 exe 放进本目录，仓库即可直接使用。脚本会自动在自身所在目录的 `bin\` 下查找它们。

## 1. yt-dlp.exe（约 17 MB）

- 官方下载：<https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe>
- 放到：`bin\yt-dlp.exe`
- 用于：解析 X 及其他公开站点的视频地址、命令行版下载、合并分离流。
- 升级：直接覆盖同名文件即可。

## 2. ffmpeg.exe（约 139 MB）

- 官方构建：<https://github.com/BtbN/FFmpeg-Builds/releases>（下载 `ffmpeg-master-latest-win64-gpl-shared.zip` 之类，取其中 `bin\ffmpeg.exe`）
  或 <https://www.gyan.dev/ffmpeg/builds/>（`ffmpeg-release-essentials.zip`，取 `bin\ffmpeg.exe`）
- 放到：`bin\ffmpeg.exe`（**只需要这一个文件**，不需要同目录的 dll；请用静态构建版本）
- 用于：m3u8 → mp4、音视频分离流合并、必要时重编码。
- 只下载 X 的单文件 MP4、不需要 m3u8 转换时，可以**不放**这个文件。

> 为什么不在仓库里：`ffmpeg.exe` 约 139 MB，超过 GitHub 单文件 100 MB 的硬上限，
> 用普通提交会被拒绝；本仓库保持纯文本源码，clone 后按上面两步补齐即可。

## 校验

放好后目录应类似：

```
bin/
├─ README.md      ← 本文件
├─ yt-dlp.exe
└─ ffmpeg.exe
```

在 PowerShell 里可执行 `bin\yt-dlp.exe --version` 和 `bin\ffmpeg.exe -version` 确认可用。
