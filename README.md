# x-video-tools

一套 **Windows 免安装便携工具集**：X / Twitter 视频批量下载、m3u8 批量转 mp4。
纯 PowerShell 5.1 + WinForms + 系统自带组件，不需要 Python、不需要安装、不需要管理员权限。

> 仓库只包含源码与说明。两个依赖程序（`yt-dlp.exe`、`ffmpeg.exe`）因体积与 GitHub 单文件上限未入库，
> 请按 [bin/README.md](bin/README.md) 下载后放进 `bin\`，即可直接双击使用。

---

## 功能

| 入口 | 用途 |
| --- | --- |
| `X视频批量下载.vbs` | **推荐**。无黑框窗口版：批量队列、断点续传、系统托盘常驻、点 × 后台继续下载 |
| `m3u8批量转换.vbs` | **推荐**。无黑框窗口版：批量/递归目录转换 m3u8 → mp4，同样支持托盘常驻 |
| `X视频批量下载.bat` / `m3u8批量转换.bat` | 兼容入口，转发给对应 `.vbs`，可拖放链接或文件到图标上预加载 |
| `下载X视频.bat` | 命令行版：单条推文下载 |
| `获取X视频直链-给FDM.bat` | 只解析出真实 MP4 直链，交给 FDM / 其他下载器 |
| `通用视频下载.bat` | 命令行版：yt-dlp 支持的公开站点通用下载 |
| `m3u8转mp4.bat` | 命令行版：单个 m3u8 转 mp4 |

主要特性：

- **断点续传**：固定推文 ID 命名 + `curl -C -` 字节续传，`.xdl_state.json` 记录进度，跨会话恢复；服务器忽略 Range 时自动完整重下。
- **受限推文兜底**：X 解析失败时改走 `fxtwitter` / `vxtwitter` 公开镜像；也可放 `cookies.txt` 登录使用。
- **代理自动识别**：命令行 `-Proxy` → Windows 系统代理 → 环境变量 → 常见本地端口（7897/7890/10809/1080/2080/33210）。
- **托盘常驻**：点右上角 × 只隐藏窗口，任务在后台继续；双击托盘图标恢复；托盘右键「退出程序」才真正退出。
- **无黑框启动**：`.vbs` 是 Windows 自带图形脚本宿主，启动 PowerShell 时不创建控制台窗口。
- m3u8 转换三级策略：无损 `-c copy` → `aac_adtstoasc` → 重编码；支持拖入整个文件夹自动收集 `.m3u8`。

## 快速开始

1. 克隆或下载本仓库到任意文件夹（Win10 1803+ / Win11）。
2. 按 [bin/README.md](bin/README.md) 把 `yt-dlp.exe` 和 `ffmpeg.exe` 放进 `bin\`。
3. 双击 `X视频批量下载.vbs` 或 `m3u8批量转换.vbs`。
4. 完整参数、代理配置、常见问题见 [使用说明.txt](使用说明.txt)。

> 只想用命令行黑框版的话，X 下载只需要 `yt-dlp.exe`；`ffmpeg.exe` 仅在合并分离流 / m3u8 转换时才需要。

## 目录结构

```
.
├─ x_video_gui.ps1          窗口版 X 批量下载主程序
├─ m3u8_gui.ps1             窗口版 m3u8 批量转换主程序
├─ x_video_dl.ps1           命令行版 X / 通用下载引擎
├─ m3u8_to_mp4.ps1          命令行版 m3u8 转换引擎
├─ *.vbs / *.bat            启动器（见上表）
├─ 使用说明.txt             完整使用文档
├─ bin/README.md            两个依赖程序的下载与放置说明
└─ docs/                    各阶段改造的交付说明与验证记录
```

## 编码注意（重要）

所有 `.ps1` 必须保存为 **UTF-8 with BOM**。Windows PowerShell 5.1 会把无 BOM 的 UTF-8 中文按 ANSI 读取，
导致大量假语法错误。`.bat` 因含中文文件名，保存为 **ANSI(GBK / 代码页 936)**；`.vbs` 为纯 ASCII。
从本仓库克隆下来的文件已保持上述编码，请勿用会去掉 BOM 的编辑器另存。

## 依赖与兼容性

| 组件 | 来源 | 是否入库 |
| --- | --- | --- |
| Windows PowerShell 5.1 | 系统自带 | — |
| .NET Framework / WinForms | 系统自带 | — |
| `wscript.exe` | 系统自带 | — |
| `curl.exe` | Win10 1803+ / Win11 自带 | — |
| `yt-dlp.exe` | [yt-dlp Releases](https://github.com/yt-dlp/yt-dlp/releases/latest) | 否（约 17 MB） |
| `ffmpeg.exe` | [BtbN FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds/releases) 或 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) | 否（约 139 MB，超 GitHub 单文件 100 MB 上限） |

## 使用边界

请仅用于下载、保存**你自己有权保存**的内容，并遵守目标平台的服务条款与所在地法律。
本工具不包含任何绕过登录、付费墙或访问控制的能力，也不针对特定第三方站点做适配。

## 状态与版本

- 2026-11-24 完成：窗口版批量下载 + 断点续传 → 系统托盘常驻 → 无黑框启动。
- 详细验证结果与未实测项见 [docs/](docs/)：`交付说明-窗口版批量下载.md`、`交付说明-系统托盘常驻.md`、`交付说明-无黑框启动.md`。
- 已在 Windows PowerShell 5.1 实跑验证：语法 0 错误、GUI 构建自检、托盘闭环、无黑框启动、本地 Range 服务断点续传 5/5 通过。
- 未自动化实测：托盘右键菜单人工点击、忙碌状态退出确认框交互、真实资源管理器拖放到 `.vbs` 图标、非中文系统下 bat 的中文文件名。
