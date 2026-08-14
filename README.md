# Hermit-Hermes：Hermes Desktop 便携构建与更新工具

Hermit（隐士）寓意本项目为其构建一个完全隔离、自包含的便携环境——不依赖系统环境，独立运行。

`Hermit-Hermes` 基于 Hermes Agent 官方正式版源码构建便携式的 Windows 版 Hermes Desktop。对上游源码 0 变更，仅在构建生成环节注入便携环境引导。

上游源码：<https://github.com/NousResearch/hermes-agent>

## 特点

- **安装/更新一体**：无版本记录时全新安装，有记录时更新；`-Tag` 指定版本构建，`-Tag` 空值查询近 10 个版本、`-Tag listall` 查询全部历史版本
- **自带运行环境**：内置 Python、Node.js、Git、uv、ripgrep、FFmpeg、Chromium 等运行时与工具，全部依赖、缓存与用户数据也均置于 Hermes 目录内。与系统环境完全隔离，不依赖系统预装的任何工具链，也无需管理员权限。
- **失败不破坏现有版本**：发布采用原子换名 + `__old` 兜底，验证全部通过后才删除旧版本
- **可整体移动**：Hermes.exe 启动时自动从自身路径推导根目录并自修复内部路径，目录移动或改名后照常运行；修复失败会阻止启动，不带异常运行
- **适用群体**：例如：不想在硬盘中多处生成目录（文件、残留）的、移动硬盘中便携使用的、系统中环境（依赖）有频繁变动需求的......
- **注意事项**：由于 Node.js（node_modules）含大量依赖包，迁移 Hermes 目录时，建议先对目录tar或7z打包，移动压缩包到指定目录后解压，**否则会变得不幸！！！**

## 使用前准备

- Windows 10/11 x64（系统需自带 `tar.exe`），PowerShell 5.1 或更高版本
- 至少 8 GB 内存，推荐 16 GB
- 网络需要能稳定访问（中国大陆地区建议科学上网） GitHub、Node.js、Python 包源和 Chromium 下载源等
- 首次构建建议预留 12 GB 磁盘空间；Hermes 目录约 5~6 GB（只保留当前一份），实际大小随上游依赖变化
- 构建前请先退出正在运行的 Hermes（文件被占用会导致发布替换失败）

## 构建

将 `Hermit-Hermes.ps1` 放在你希望保存 Hermes 的位置，在该目录打开 PowerShell 执行：

```powershell
.\Hermit-Hermes.ps1
```

若执行策略拒绝运行，可用一次性方式（不会修改系统策略）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Hermit-Hermes.ps1
```

流程：环境预检（进程/网络/磁盘）→ 版本判断 → 确认→ 引导工具 → 拉取源码 → 私有工具 → Agent 运行环境 → 桌面端打包 → 注入便携引导 → 验证发布 → 清理工作区。首次构建耗时较长（大量下载），需要稳定网络与耐心等待。如果已是最新版本，脚本会跳过构建，只验证现有 Hermes 目录后结束。

首次全新安装成功后，脚本会把自己复制到 `Hermes\Hermit-Hermes.ps1` 并删除根目录原件；之后更新直接运行 Hermes 内的副本即可，副本通过 `Hermes\manifests\installed.json` 自动推导构建根目录，无需手动配置。

版本范围：Hermes Desktop 自上游 v2026.6.5 起引入，v2026.6.5 之前的版本不含桌面端，无法构建出 Hermes.exe。因此 `-Tag` 查询只会列出 v2026.6.5 及以后的版本；若指定更早版本（如 `-Tag v2026.5.29`），脚本会提示该版本不可构建并退出。优先选择新版本，不建议使用旧版本，旧版本各种问题颇多。

## 可选参数

```powershell
# 构建指定正式版；-Tag 不带值查询近 10 个版本，-Tag listall 查询全部历史版本
.\Hermit-Hermes.ps1 -Tag v2026.8.3

# 构建失败后保留临时源码工作树，方便排查
.\Hermit-Hermes.ps1 -KeepBuild

# 构建开始前跳过确认提示（用于自动化）
.\Hermit-Hermes.ps1 -SkipConfirm

# 备份个人数据（配置/数据库/会话等必要数据）到 Hermes\backups\ 目录
.\Hermit-Hermes.ps1 -Backup
```

## 启动 Hermes

直接双击 `Hermes\app\Hermes.exe` 即可（或自行发送到桌面快捷方式，但移动 Hermes 目录后需要手动修正）。

## 目录说明

```text
Hermit-Hermes.ps1         构建/更新脚本（首次运行入口）
Hermes\                   Hermes 应用与运行环境（可整个打包分发）
├─ Hermit-Hermes.ps1      构建/更新脚本副本（首次安装后自动迁入）
├─ app\                   Hermes Desktop（Hermes.exe 为启动入口）
├─ backups\               个人数据备份目录（配置/数据库/会话等必要数据）
├─ runtime\               Agent 与私有运行环境（CPython（含 venv）、Node、Git、uv、Playwright 浏览器）
├─ tools\                 ripgrep 与 FFmpeg
├─ data\                  Hermes 私有配置、日志和用户数据
├─ manifests\             已构建版本信息（installed.json）
└─ build\                 构建工作区（缓存/日志，可随时删除）
```

`Hermes\build\` 只用于加速后续构建与排查，分发前删除即可。分发请使用全新构建的版本，避免个人数据与大量缓存被意外带出。

## 发布机制

- 新版本先在 `Hermes\build\` 候选目录中构建并验证，验证全部通过后发布
- 发布时把当前版本短暂移至 `__old` 兜底，再原子换名发布新版本，随后删除 `__old`；磁盘上只保留当前一份版本
- 发布后自动清理根目录中不属于标准结构的多余残留（旧版 cache、标记文件等），Hermes 目录保持干净
- 大量依赖复用缓存：下载包 SHA-256 校验命中、Node 主版本未变直接复制、私有工具版本相同跳过重装、Chromium 已安装则跳过下载
- 所有构建都不会改动 `data\` 中的用户数据

## 脚本发布与更新

`Hermit-Hermes.ps1` 自身通过 GitHub Releases 发布并自动更新：

- 每次运行会先检查最新版本（`qzry/Hermit-Hermes` 仓库），有新版本必须先更新，通过后才能进入构建流程
- 更新时下载 `Hermit-Hermes.ps1`，SHA-256 直接取自 GitHub 官方为资产计算的 digest，校验通过后替换自身，并提示重新运行
- 检查失败（网络不通、仓库无 Release、资产缺失或校验失败）会阻止构建，避免使用未知或损坏的脚本

## 故障处理

- 构建时请从已打开的 PowerShell 执行脚本，不建议双击 `.ps1`，以免报错后窗口关闭
- 运行前会先做环境预检（进程、网络、磁盘空间）；互不依赖的长任务并行执行
- 失败时显示诊断卡片（阶段、原因、日志路径、处理建议）；完整日志：`Hermes\build\logs\build-日期-时间.log`
- 若 Hermes.exe 启动异常，请查看 `Hermes\data\logs\desktop.log`

### 重建即修复

程序层故障（依赖损坏、文件缺失、启动异常、功能异常等）可通过重建「重装」修复：

- 先退出正在运行的 Hermes，再执行 `.\Hermit-Hermes.ps1 -Tag <当前版本>` 强制重建当前版本（可执行 `-Tag` 不带查询值查询当前版本信息）；不带 `-Tag` 且已是最新版本时，脚本只做完整性校验、不会重建
- 重建会重新生成 `runtime\`（Python venv、全部依赖、Node、Git、uv、Playwright 浏览器）与 `app\`（Hermes.exe 桌面端），相当于程序层全新重装
- 发布采用原子换名 + `__old` 兜底，重建失败不会破坏现有版本
- `data\` 个人数据完全不受影响；若问题出在个人数据（配置/数据库损坏等），重建无法修复，应先执行 `.\Hermit-Hermes.ps1 -Backup` 备份，再重置 `data\`

## 官方安装器残留清单

以下内容来自上游 v2026.8.3 的 `scripts/install.ps1`、`apps/bootstrap-installer` 与 `apps/desktop`，为本构建器刻意完全避免的系统级痕迹；上游后续版本可能变化，以源码为准：

```text
目录：
%LOCALAPPDATA%\hermes                        Hermes 主目录（hermes-agent\、git\、bin\、logs\、
                                             bootstrap-cache\、hermes-setup.exe、更新标记等）
%LOCALAPPDATA%\hermes\hermes-agent\          Agent 安装与 Python venv
%LOCALAPPDATA%\uv                            uv 缓存（UV_CACHE_DIR 默认值）
%APPDATA%\uv                                 uv 数据目录（托管的 Python 与工具）
%USERPROFILE%\.local\bin                     uv 工具可执行文件目录（UV_TOOL_BIN_DIR 默认值）
%LOCALAPPDATA%\ms-playwright                 Playwright 浏览器（Chromium）
%LOCALAPPDATA%\electron\Cache                Electron 缓存
%LOCALAPPDATA%\com.nousresearch.hermes.setup Tauri 安装器数据（WebView2 等）
%APPDATA%\Hermes                             Electron 桌面端默认用户数据目录
%LOCALAPPDATA%\Microsoft\WinGet              winget 数据与命令别名

快捷方式文件：
%USERPROFILE%\Desktop\Hermes.lnk
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Hermes.lnk

用户环境变量：
HERMES_HOME              = %LOCALAPPDATA%\hermes
HERMES_GIT_BASH_PATH     = %LOCALAPPDATA%\hermes\git\bin\bash.exe

用户环境变量 Path 追加：
%LOCALAPPDATA%\hermes\hermes-agent\venv\Scripts
%LOCALAPPDATA%\hermes\bin
%LOCALAPPDATA%\Microsoft\WinGet\Links

winget 可能额外安装（视系统环境）：
Python 3.11（Python.Python.3.11）→ %LOCALAPPDATA%\Programs\Python\Python311
Node.js LTS（OpenJS.NodeJS.LTS）→ %ProgramFiles%\nodejs（系统级 MSI，需管理员）
ripgrep（BurntSushi.ripgrep.MSVC）、FFmpeg（Gyan.FFmpeg）→ 由 winget 管理
```