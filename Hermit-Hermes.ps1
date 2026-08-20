<#
Hermit-Hermes：Hermes Desktop 便携构建与更新工具（安装/更新一体，完全便携）。

作者：轻舟入屿
联系方式：onewit@qq.com
版本：v1.0.3

常规使用：
  .\Hermit-Hermes.ps1

构建指定正式版：
  .\Hermit-Hermes.ps1 -Tag v2026.8.3

列出可安装的正式版本（最近 10 个）：
  .\Hermit-Hermes.ps1 -Tag

列出全部历史版本：
  .\Hermit-Hermes.ps1 -Tag listall

构建失败后保留临时源码工作树：
  .\Hermit-Hermes.ps1 -KeepBuild

跳过构建前的确认提示（用于自动化）：
  .\Hermit-Hermes.ps1 -SkipConfirm

备份个人数据到 Hermes\backups\（配置/数据库/会话等必要数据）：
  .\Hermit-Hermes.ps1 -Backup

移动 Hermes 目录后无需手动修复：Hermes.exe 启动时会自动检测并修复
内置 Python 环境的路径（内联引导；修复失败会阻止启动）。

每次运行都会先检查脚本自身更新（GitHub Releases 发布 Hermit-Hermes.ps1，
SHA-256 由 GitHub 官方 digest 自动校验）：有新版本必须先更新，通过后才能进入构建流程。
#>

[CmdletBinding()]
param(
    [Parameter(Position = 1)]
    [string]$Root = '',

    # 指定构建版本；不写 -Tag 表示最新的非预发布 GitHub Release，
    # 写 -Tag 但不带值时列出可安装版本
    [Alias('Tag')]
    [switch]$TagFlag,

    # 收集 -Tag 后面的版本号（-Tag 声明为 switch 以支持空值；版本号作为位置参数优先绑定到这里）
    [Parameter(Position = 0)]
    [string[]]$TagValues,

    # 只备份 Hermes 个人数据（配置/数据库/会话等必要数据）到 Hermes\backups\，不构建
    [switch]$Backup,

    # 构建失败排查时保留临时源码工作树
    [switch]$KeepBuild,

    # 构建开始前跳过确认提示（用于自动化）
    [switch]$SkipConfirm
)

Set-StrictMode -Version Latest

# -Tag 以 switch 形式声明以支持空值（.\Hermit-Hermes.ps1 -Tag 直接列出可安装版本）；
# 版本号经 TagValues 收集，规整为单个字符串
$script:TagSpecified = $PSBoundParameters.ContainsKey('TagFlag')
$Tag = if ($TagFlag) { if ($TagValues) { ($TagValues -join ' ').Trim() } else { '' } } else { '' }
# 未写 -Tag 却出现裸参数时给出提示，避免被静默忽略
if (-not $script:TagSpecified -and $TagValues) {
    Write-Host "Unrecognized argument(s): $($TagValues -join ' ')" -ForegroundColor Yellow
    Write-Host 'Use -Tag <version> to build a specific version, or -Tag to list versions.' -ForegroundColor Gray
    return
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 状态行使用的控制台符号，仅选用 Windows 10 自带控制台字体（Consolas / NSimSun）能显示的字符
# U+26A0（警告标志）在 Consolas 中缺失，因此警告标记保持 ASCII
# 文件为 UTF-8 BOM；符号仍用码点生成，与历史版本显示保持一致
$script:SymInfo = [string][char]0x2192
$script:SymOk = [string][char]0x2713
$script:SymErr = [string][char]0x2717
$script:SymWarn = '!'

# 原生工具（git checkout/fetch 等）会输出帧式进度，例如
# "Updating files: 22% (1886/8436)"，经管道转发时每帧一行
# 这些行在单行内原位刷新，而不是滚动刷屏
$script:ProgressLinePattern = '^\s*[A-Za-z][A-Za-z ]*:\s*\d+%\s*\(\d+/\d+\)'

# 防止 Git、Python、npm 及上游源码元数据的 UTF-8 输出
# 被旧的 Windows 控制台代码页错误解码
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
}
catch {
    Write-Warning 'Unable to switch console output to UTF-8; build output may contain garbled text.'
}

# Hermes 目录：副本模式时在下方直接取自脚本所在目录，因此目录改名/移动后副本仍能指向正确位置
try {
    $script:HermesDir = $null
    if ([string]::IsNullOrWhiteSpace($Root)) {
        # 脚本所在目录存在 manifests\installed.json，说明脚本是 Hermes 目录内的副本，
        # 此时构建根目录为 Hermes 目录的上一级；否则脚本所在目录即为构建根目录
        $scriptDir = Split-Path -Parent $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
        if (Test-Path -LiteralPath (Join-Path $scriptDir 'manifests\installed.json')) {
            # 副本模式：Hermes 目录就是脚本所在目录（目录改名/移动后依然正确），
            # 构建根目录为 Hermes 目录的上一级
            $script:HermesDir = [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\\')
            $scriptDir = Split-Path -Parent $scriptDir
        }
        $Root = [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\\')
    }
    
    $script:Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\\')
    if (-not $script:HermesDir) {
        # 根目录模式（首次安装）：Hermes 目录固定为 Root\Hermes
        $script:HermesDir = Join-Path $script:Root 'Hermes'
    }
    # 构建工作区（缓存/源码/解压/日志）位于 Hermes 目录内的 build\ 子目录，
    # 与 Hermes 内容（app/runtime/tools/data/manifests）分开，发人时只需打包这五个目录
    $script:BuildDir = Join-Path $script:HermesDir 'build'
    $script:SourceRepo = 'https://github.com/NousResearch/hermes-agent.git'
    $script:GitHubHeaders = @{ 'User-Agent' = 'Hermes-Builder' }
    # 脚本自更新：发布在 GitHub Releases（Hermit-Hermes.ps1，SHA-256 取自官方 digest）
    $script:ScriptVersion = 'v1.0.3'
    $script:RepoOwner = 'qzry'
    $script:RepoName = 'Hermit-Hermes'
    $script:LogFile = $null
    $script:LogWriter = $null
    $script:CurrentStage = 'Startup'
    $script:LastStatusLength = 0
    $script:LastFallbackStatus = [DateTime]::MinValue
    # 构建开始前是否已有版本记录（决定构建后是否迁移脚本自身；首次安装才迁移）
    $script:HadInstall = $false
}
catch {
    # 初始化失败（如路径无效）时与主流程一致：只显示错误卡，不打印红字堆栈
    Show-FailureCard -Failure $_.Exception.Message
    return
}

function Write-BuildLog {
    # 向当前构建日志追加一行带时间戳的记录（Start-BuildLog 之前为空操作）
    param([string]$Message, [string]$Level = 'INFO', [string]$Source = $script:CurrentStage)
    if (-not $script:LogWriter) { return }
    $safeMessage = ([string]$Message).Replace("`r", '').Replace("`n", ' ')
    # 省略年份：日志文件名已含完整日期
    # 级别列补齐宽度，使每行对齐便于扫读
    $timestamp = Get-Date -Format 'MM-dd HH:mm:ss.fff'
    $script:LogWriter.WriteLine("[$timestamp] [$($Level.PadRight(5))] [$Source] $safeMessage")
}

function Start-BuildLog {
    # 在 Hermes\build\logs 下创建构建日志文件并打开写入器
    $directory = Join-Path $script:BuildDir 'logs'
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $script:LogFile = Join-Path $directory "build-$stamp.log"
    $script:LogWriter = New-Object System.IO.StreamWriter($script:LogFile, $false, [System.Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    Write-BuildLog "Build started. Root=$($script:Root) Hermes=$($script:HermesDir)" -Source 'main'
}

function Stop-BuildLog {
    # 刷新并关闭构建日志写入器
    if ($script:LogWriter) {
        $script:LogWriter.Dispose()
        $script:LogWriter = $null
    }
}

function Show-FailureCard {
    # 失败时输出结构化诊断卡（阶段/原因/日志路径/处理建议）
    param([string]$Failure)
    Clear-TaskStatusLine
    # 按错误关键词分类，给出针对性的下一步建议
    $hint = switch -Regex ($Failure) {
        'currently running' { 'Close Hermes Desktop, then re-run the script.' }
        'agent process is still running' { 'Close Hermes and any leftover Hermes python processes, then re-run the script.' }
        'previous version is still in use' { 'Close Hermes and any leftover Hermes python processes, then re-run the script.' }
        'SHA-256|verification failed' { 'The downloaded file is corrupt; it will be re-downloaded on retry.' }
        'network|connect|cannot reach|无法连接|连接超时|不能连接' { 'Check your network or proxy, then re-run the script.' }
        'space|disk' { 'Free up disk space, then re-run the script.' }
        'Source directory is missing' { 'The source tree is missing - re-run the script to re-fetch it.' }
        'install is incomplete|was not installed' { 'The install is incomplete - re-run the script to rebuild.' }
        'Required executable is missing|tar.exe is required' { 'A required tool is missing (e.g. Windows tar.exe) - see the README prerequisites.' }
        'CPython is missing|venv|pyvenv.cfg' { 'The bundled Python environment is damaged - re-run the script to rebuild.' }
        'exit code' { 'A build command failed - check the log for the failing command.' }
        default { 'Check the log for details, then re-run the script.' }
    }
    $rule = '=' * 50
    Write-Host ''
    Write-Host $rule -ForegroundColor Red
    Write-Host ("  {0} Build failed  " -f $script:SymErr) -ForegroundColor Red
    Write-Host $rule -ForegroundColor Red
    Write-Host ("  Stage    : $($script:CurrentStage)") -ForegroundColor White
    Write-Host ("  Reason   : $Failure") -ForegroundColor White
    if ($script:LogFile) {
        Write-Host ("  Log      : $($script:LogFile)") -ForegroundColor Yellow
    }
    Write-Host ("  Next     : $hint") -ForegroundColor Cyan
    Write-Host $rule -ForegroundColor Red
    Write-Host ''
}

function Show-SuccessCard {
    # 构建完全成功后输出绿色完成卡（版本/路径/下一步），与错误卡风格对应
    param([string]$Version, [string]$HermesPath)
    $rule = '=' * 50
    Write-Host ''
    Write-Host $rule -ForegroundColor Green
    Write-Host ("  {0} Build completed  " -f $script:SymOk) -ForegroundColor Green
    Write-Host $rule -ForegroundColor Green
    if ($Version) { Write-Host ("  Version : $Version") -ForegroundColor White }
    Write-Host ("  Hermes  : $HermesPath") -ForegroundColor White
    Write-Host '  Next    : Run Hermes.exe to start' -ForegroundColor Gray
    Write-Host $rule -ForegroundColor Green
    Write-Host ''
}

function Show-StartCard {
    # 启动品牌卡：脚本名称/版本/仓库，与确认卡同风格（DarkCyan 分隔线 + 标题背景）
    $rule = '=' * 50
    Write-Host ''
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host ("  Hermit-Hermes $script:ScriptVersion  ") -ForegroundColor White -BackgroundColor DarkCyan
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host '  Name    : Hermes Desktop portable builder for Windows' -ForegroundColor White
    Write-Host ("  Repo    : github.com/$script:RepoOwner/$script:RepoName") -ForegroundColor Gray
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host ''
}
function Write-Info([string]$Message, [string]$Source = $script:CurrentStage) {
    # 输出信息行（青色箭头）并记录日志
    Write-BuildLog $Message 'INFO' $Source
    Clear-TaskStatusLine
    Write-Host "[Hermes] $script:SymInfo $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message, [string]$Source = $script:CurrentStage) {
    # 输出成功行（绿色对勾）并记录日志
    Write-BuildLog $Message 'OK' $Source
    Clear-TaskStatusLine
    Write-Host "[Hermes] $script:SymOk $Message" -ForegroundColor Green
}
function Write-WarnPortable([string]$Message, [string]$Source = $script:CurrentStage) {
    # 输出警告行（黄色感叹号）并记录日志
    Write-BuildLog $Message 'WARN' $Source
    Clear-TaskStatusLine
    # 用普通黄色行替代 Write-Warning：原生的 WARNING: 前缀
    # 与符号重复且无法统一着色
    Write-Host "[Hermes] $script:SymWarn $Message" -ForegroundColor Yellow
}

function Write-Stage {
    # 输出阶段横幅（如 [3/6] 安装工具）并记录当前阶段
    param([Parameter(Mandatory)][string]$Name, [string]$Step = '')
    $script:CurrentStage = if ($Step) { "[$Step] $Name" } else { $Name }
    Write-BuildLog "Stage started: $($script:CurrentStage)" 'STAGE' 'stage'
    Clear-TaskStatusLine
    Write-Host ''
    $title = "  $($script:CurrentStage)  "
    Write-Host $title -ForegroundColor White -BackgroundColor DarkCyan
}

function Write-InlineStatus([string]$Text) {
    # 通过 .NET 控制台 API 在单行内原位刷新，Write-Host 的
    # 回车符在某些宿主上会被展开成换行，使单行进度变成滚动日志，
    # CursorLeft + Console.Write 不会这样
    # 输出重定向或宿主非真实控制台时返回 $false，调用方可改用节流输出
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsOutputRedirected) { return $false }
    $rendered = $Text.PadRight($script:LastStatusLength)
    # 防换行保护：状态行超过窗口宽度时终端会自动换行，单行刷新随之失效
    #（看起来像多行滚动）。按窗口宽度截断，保证始终单行。
    try {
        $maxWidth = [Math]::Max([Console]::WindowWidth - 1, 40)
        if ($rendered.Length -gt $maxWidth) { $rendered = $rendered.Substring(0, $maxWidth) }
    }
    catch { }
    $previousColor = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        [Console]::CursorLeft = 0
        [Console]::Write($rendered)
    }
    catch { return $false }
    finally {
        [Console]::ForegroundColor = $previousColor
    }
    $script:LastStatusLength = $rendered.Length
    return $true
}

function Update-TaskStatus {
    # 更新任务状态行：控制台单行原位刷新，重定向/非控制台时按节流兜底输出
    param([Parameter(Mandatory)][string]$Message, [switch]$Complete, [switch]$Ok, [switch]$Fail)
    $marker = if ($Ok) { "$($script:SymOk) " } elseif ($Fail) { "$($script:SymErr) " } else { '' }
    $line = "[Hermes] $marker$Message"
    $color = if ($Ok) { 'Green' } elseif ($Fail) { 'Red' } else { 'Cyan' }
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
        if ($Complete) {
            Clear-TaskStatusLine
            Write-Host $line -ForegroundColor $color
        }
        else {
            # 必须消费返回值：Write-InlineStatus 返回 $true/$false，
            # 裸语句会让返回值泄漏到输出流（行尾出现 True/False）
            $null = Write-InlineStatus $line
        }
        return
    }
    # 输出重定向或非控制台宿主时的兜底：周期性输出
    if ($Complete -or ((Get-Date) - $script:LastFallbackStatus).TotalSeconds -ge 15) {
        Write-Host $line -ForegroundColor $color
        $script:LastFallbackStatus = Get-Date
    }
}

function Clear-TaskStatusLine {
    # 在其它控制台输出前擦除原位状态行，
    # 避免两者交错留下残影
    if ($script:LastStatusLength -gt 0 -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
        $previousColor = [Console]::ForegroundColor
        try {
            [Console]::ForegroundColor = [ConsoleColor]::Cyan
            [Console]::CursorLeft = 0
            [Console]::Write((' ' * $script:LastStatusLength))
            [Console]::CursorLeft = 0
        }
        catch { }
        finally {
            [Console]::ForegroundColor = $previousColor
        }
        $script:LastStatusLength = 0
    }
}

function Assert-PortableRoot {
    # 断言脚本运行位置在 Hermes 根目录内，防止误在别处执行构建操作
    $rootPath = [System.IO.Path]::GetFullPath($script:Root).TrimEnd('\\')
    $driveRoot = [System.IO.Path]::GetPathRoot($rootPath).TrimEnd('\\')
    if ([string]::IsNullOrWhiteSpace($rootPath) -or
        [string]::Equals($rootPath, $driveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a drive root as the Hermes directory: $rootPath"
    }
}

function Assert-UnderPortableRoot([string]$Path) {
    # 安全护栏：校验路径在 Hermes 根目录内，越界立即拒绝，防止误删/误写系统文件
    $full = [System.IO.Path]::GetFullPath($Path)
    $prefix = $script:Root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the Hermes directory: $full"
    }
    return $full
}

function Remove-PortableTree([string]$Path) {
    $full = Assert-UnderPortableRoot $Path
    if (Test-Path -LiteralPath $full) {
        # .NET 的 Directory.Delete 删除数万小文件（npm node_modules、
        # git 工作树）比 Remove-Item -Recurse 快得多，
        # 只读文件导致原生删除失败时回退到 Remove-Item
        Write-BuildLog "Removing tree: $full" 'INFO' 'fs'
        $treeName = [System.IO.Path]::GetFileName($full)
        Write-BuildLog "Cleaning up: $treeName..." 'INFO' 'fs'
        $startedAt = Get-Date
        # 清理可能耗时较长（数万小文件），在独立 job 中删除、
        # 主线程轮询并以单行状态动态刷新已用时间，避免长时间静默看似卡死；
        # 非控制台/重定向时退化为同步删除，保证日志纯净
        $interactive = ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected)
        $jobFailed = $false
        if ($interactive) {
            $deleteJob = Start-Job -ScriptBlock {
                param($target)
                [System.IO.Directory]::Delete($target, $true)
            } -ArgumentList $full
            try {
                while ($deleteJob.State -eq 'Running') {
                    Start-Sleep -Milliseconds 400
                    Update-TaskStatus "Cleaning up: $treeName... ($(Format-Elapsed ((Get-Date) - $startedAt)))"
                }
                $jobFailed = ($deleteJob.State -eq 'Failed')
            }
            finally {
                Remove-Job -Job $deleteJob -Force -ErrorAction SilentlyContinue
            }
            if ($jobFailed) {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
            }
        }
        else {
            try {
                [System.IO.Directory]::Delete($full, $true)
            }
            catch {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
            }
        }
        $removedTimeSpan = (Get-Date) - $startedAt
        $removedSeconds = [Math]::Round($removedTimeSpan.TotalSeconds)
        Write-BuildLog "Removed tree in ${removedSeconds}s: $full" 'INFO' 'fs'
        $elapsedText = if ($removedTimeSpan.TotalSeconds -ge 1) { " ($(Format-Elapsed $removedTimeSpan))" } else { '' }
        Write-Ok "Cleaned up $treeName$elapsedText" -Source 'fs'
    }
}

function Ensure-Directory([string]$Path) {
    # 目录不存在则创建（含父目录）
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    return $Path
}

function Get-ExternalLogLevel([string]$Message) {
    # 将外部工具的输出行分类为 ERROR / WARN / DEBUG
    if ($Message -match '(?i)(^|\s)(fatal|error|exception|failed|npm ERR!)(\s|:|$)') { return 'ERROR' }
    if ($Message -match '(?i)(^|\s)(warn|warning|deprecated)(\s|:|$)') { return 'WARN' }
    return 'DEBUG'
}

function Write-ExternalOutput {
    # 记录并返回一行外部命令输出
    param([object]$Record, [string]$Source)
    $message = if ($Record -is [System.Management.Automation.ErrorRecord]) { $Record.Exception.Message } else { [string]$Record }
    # git 检出/拉取的进度帧在日志中纯属噪音，
    # 命令完成行与退出码已足够表达结果
    if ($message -notmatch $script:ProgressLinePattern) {
        Write-BuildLog $message (Get-ExternalLogLevel $message) $Source
    }
    return $message
}

function Switch-PortableCwd {
    # PowerShell 作业进程初始化时会把模块分析缓存（ModuleAnalysisCache）
    # 写入"进程当前目录"；在隔离环境下该路径计算会退化为相对路径。
    # 临时把进程当前目录切到私有 LOCALAPPDATA，避免缓存目录落到
    # Hermes 根目录之外。返回调用前的进程当前目录以便恢复。
    $privateDirectory = Join-Path $script:HermesDir 'data\appdata-local'
    Ensure-Directory $privateDirectory | Out-Null
    $previous = [System.IO.Directory]::GetCurrentDirectory()
    [System.IO.Directory]::SetCurrentDirectory($privateDirectory)
    return $previous
}
function Invoke-External {
    # 执行外部命令：设置私有环境、捕获输出、记录日志、以退出码判定成败
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $PWD.Path,
        [hashtable]$Environment = @{},
        [switch]$Quiet,
        [string]$Activity = '',
        [string]$LogSource = ''
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Required executable is missing: $FilePath"
    }

    $before = @{}
    foreach ($key in $Environment.Keys) {
        $before[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    Push-Location $WorkingDirectory
    $previousEap = $ErrorActionPreference
    $startedAt = Get-Date
    $source = if ($LogSource) { $LogSource } else { $script:CurrentStage }
    $commandText = "$FilePath $($Arguments -join ' ')"
    $errorTail = [System.Collections.Generic.List[string]]::new()
    Write-BuildLog "Command: $commandText" 'INFO' $source
    try {
        # 原生工具通常把正常进度写到 stderr，退出码才是可靠信号
        $ErrorActionPreference = 'Continue'
        # 许多原生工具（如 uv、Git、FFmpeg）用 stderr 输出正常进度，
        # PowerShell 默认把这类记录标红为 NativeCommandError 并附带无关的脚本位置，
        # 因此将每一行渲染为普通控制台文本，
        # 退出码仍是权威的失败信号
        if ($Quiet) {
            $previousCwd = Switch-PortableCwd
            try {
                $job = Start-Job -ScriptBlock {
                    param($Executable, $NativeArguments, $Directory)
                    Push-Location $Directory
                    try {
                        & $Executable @NativeArguments 2>&1
                        $code = $LASTEXITCODE
                    }
                    finally {
                        Pop-Location
                    }
                    [pscustomobject]@{ __HermesExitCode = $code }
                } -ArgumentList $FilePath, $Arguments, $WorkingDirectory
            }
            finally {
                [System.IO.Directory]::SetCurrentDirectory($previousCwd)
            }
            $exitCode = $null
            $lastStatus = [DateTime]::MinValue
            $label = if ($Activity) { $Activity } else { $source }
            try {
                while ($true) {
                    @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | ForEach-Object {
                        if ($_.PSObject.Properties.Match('__HermesExitCode').Count -gt 0) {
                            $exitCode = [int]$_.__HermesExitCode
                        }
                        else {
                            $rec = Write-ExternalOutput -Record $_ -Source $source
                            if ($rec -and (Get-ExternalLogLevel $rec) -eq 'ERROR') {
                                if ($errorTail.Count -ge 3) { $errorTail.RemoveAt(0) }
                                $errorTail.Add($rec)
                            }
                        }
                    }
                    if ($job.State -ne 'Running') { break }
                    $now = Get-Date
                    if (($now - $lastStatus).TotalSeconds -ge 1) {
                        $elapsed = $now - $startedAt
                        Update-TaskStatus "$label running ($(Format-Elapsed $elapsed))"
                        $lastStatus = $now
                    }
                    Start-Sleep -Milliseconds 400
                }
                @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | ForEach-Object {
                    if ($_.PSObject.Properties.Match('__HermesExitCode').Count -gt 0) {
                        $exitCode = [int]$_.__HermesExitCode
                    }
                    else {
                        $rec = Write-ExternalOutput -Record $_ -Source $source
                        if ($rec -and (Get-ExternalLogLevel $rec) -eq 'ERROR') {
                            if ($errorTail.Count -ge 3) { $errorTail.RemoveAt(0) }
                            $errorTail.Add($rec)
                        }
                    }
                }
            }
            finally {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
            if ($null -eq $exitCode) { $exitCode = 1 }
            $elapsed = (Get-Date) - $startedAt
            $timeText = if ($elapsed.TotalSeconds -ge 1) { " ($(Format-Elapsed $elapsed))" } else { '' }
            if ($exitCode -eq 0) {
                Update-TaskStatus "$label$timeText" -Complete -Ok
            }
            else {
                Update-TaskStatus "$label$timeText" -Complete -Fail
            }
        }
        else {
            $lastProgressLine = [DateTime]::MinValue
            & $FilePath @Arguments 2>&1 | ForEach-Object {
                $message = Write-ExternalOutput -Record $_ -Source $source
                if ($message -match $script:ProgressLinePattern) {
                    # 帧式进度：在单行内原位重绘
                    $progressText = '[Hermes] ' + $message.Trim()
                    if (-not (Write-InlineStatus $progressText)) {
                        # 输出重定向或非控制台宿主：节流兜底
                        if (((($now = Get-Date) - $lastProgressLine).TotalSeconds) -ge 5) {
                            Write-Host $progressText -ForegroundColor Cyan
                            $lastProgressLine = $now
                        }
                    }
                }
                else {
                    Clear-TaskStatusLine
                    $level = Get-ExternalLogLevel $message
                    if ($level -eq 'ERROR' -and $message) {
                        if ($errorTail.Count -ge 3) { $errorTail.RemoveAt(0) }
                        $errorTail.Add($message)
                    }
                    $color = if ($level -eq 'ERROR') { 'Red' } elseif ($level -eq 'WARN') { 'Yellow' } else { 'DarkCyan' }
                    Write-Host ("  " + $message) -ForegroundColor $color
                }
            }
            Clear-TaskStatusLine
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
        Pop-Location
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $before[$key], 'Process')
        }
    }

    if ($exitCode -ne 0) {
        Write-BuildLog "Command failed with exit code ${exitCode}: $commandText" 'ERROR' $source
        $commandName = Split-Path -Leaf $FilePath
        $lastError = if ($errorTail.Count -gt 0) { $errorTail[$errorTail.Count - 1] } else { '' }
        if ($lastError) {
            throw "Command failed with exit code ${exitCode}: $commandName - $lastError"
        }
        else {
            throw "Command failed with exit code ${exitCode}: $commandName"
        }
    }
    Write-BuildLog "Command completed in $([Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)) seconds: $commandText" 'INFO' $source
}

function Invoke-ExternalParallel {
    # 并发执行多个互不依赖的外部命令（每命令一个后台作业），等待全部结束统一判定退出码（wait-all）
    param(
        [Parameter(Mandatory)][object[]]$Commands,
        [Parameter(Mandatory)][hashtable]$Environment,
        [string]$Activity = 'Parallel tasks',
        [string]$LogSource = 'parallel'
    )

    $startedAt = Get-Date
    $jobErrors = @{}
    $previousCwd = Switch-PortableCwd
    try {
        $jobs = foreach ($cmd in $Commands) {
            Write-BuildLog "Command: $($cmd.FilePath) $($cmd.Arguments -join ' ')" 'INFO' $LogSource
            Start-Job -ScriptBlock {
                param($FilePath, $NativeArguments, $Directory, $EnvTable)
                foreach ($key in $EnvTable.Keys) {
                    [Environment]::SetEnvironmentVariable($key, [string]$EnvTable[$key], 'Process')
                }
                Push-Location $Directory
                try {
                    & $FilePath @NativeArguments 2>&1
                    $code = $LASTEXITCODE
                }
                finally {
                    Pop-Location
                }
                [pscustomobject]@{ __HermesExitCode = $code }
            } -ArgumentList $cmd.FilePath, $cmd.Arguments, $cmd.WorkingDirectory, $Environment
        }
    }
    finally {
        [System.IO.Directory]::SetCurrentDirectory($previousCwd)
    }

    $exitCodes = @{}
    $lastStatus = [DateTime]::MinValue
    try {
        # wait-all 策略：不打断任何任务（避免强杀留子进程/锁），
        # 只轮询等待全部结束，最后统一检查退出码
        while ($true) {
            $running = @($jobs | Where-Object { $_.State -eq 'Running' })
            foreach ($job in $jobs) {
                # 持续收集中间输出；作业结束时返回 __HermesExitCode 作为退出码信号
                @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | ForEach-Object {
                    if ($_.PSObject.Properties.Match('__HermesExitCode').Count -gt 0) {
                        $exitCodes[$job.Id] = [int]$_.__HermesExitCode
                    }
                    else {
                        $rec = Write-ExternalOutput -Record $_ -Source $LogSource
                        if (-not $jobErrors.ContainsKey($job.Id)) { $jobErrors[$job.Id] = [System.Collections.Generic.List[string]]::new() }
                        if ($rec -and (Get-ExternalLogLevel $rec) -eq 'ERROR') {
                            $list = $jobErrors[$job.Id]
                            if ($list.Count -ge 3) { $list.RemoveAt(0) }
                            $list.Add($rec)
                        }
                    }
                }
            }
            if ($running.Count -eq 0) { break }
            $now = Get-Date
            if (($now - $lastStatus).TotalSeconds -ge 1) {
                $elapsed = $now - $startedAt
                Update-TaskStatus "$Activity ($($jobs.Count - $running.Count)/$($jobs.Count) done) ($(Format-Elapsed $elapsed))"
                $lastStatus = $now
            }
            Start-Sleep -Milliseconds 400
        }
        # 全部结束后再收一次输出，确保每个作业的退出码都已落袋
        foreach ($job in $jobs) {
            @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | ForEach-Object {
                if ($_.PSObject.Properties.Match('__HermesExitCode').Count -gt 0) {
                    $exitCodes[$job.Id] = [int]$_.__HermesExitCode
                }
                else {
                    $rec = Write-ExternalOutput -Record $_ -Source $LogSource
                    if (-not $jobErrors.ContainsKey($job.Id)) { $jobErrors[$job.Id] = [System.Collections.Generic.List[string]]::new() }
                    if ($rec -and (Get-ExternalLogLevel $rec) -eq 'ERROR') {
                        $list = $jobErrors[$job.Id]
                        if ($list.Count -ge 3) { $list.RemoveAt(0) }
                        $list.Add($rec)
                    }
                }
            }
        }
    }
    finally {
        foreach ($job in $jobs) {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $code = if ($exitCodes.ContainsKey($jobs[$i].Id)) { $exitCodes[$jobs[$i].Id] } else { 1 }
        if ($code -ne 0) {
            $text = "$($Commands[$i].FilePath) $($Commands[$i].Arguments -join ' ')"
            Write-BuildLog "Parallel command failed with exit code ${code}: $text" 'ERROR' $LogSource
            $commandName = Split-Path -Leaf $Commands[$i].FilePath
            $failedJobId = $jobs[$i].Id
            $lastError = ''
            if ($jobErrors.ContainsKey($failedJobId) -and $jobErrors[$failedJobId].Count -gt 0) {
                $lastError = $jobErrors[$failedJobId][$jobErrors[$failedJobId].Count - 1]
            }
            if ($lastError) {
                throw "Parallel command failed with exit code ${code}: $commandName - $lastError"
            }
            else {
                throw "Parallel command failed with exit code ${code}: $commandName"
            }
        }
        Write-BuildLog "Parallel command completed in $([Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))s: $($Commands[$i].FilePath) $($Commands[$i].Arguments -join ' ')" 'INFO' $LogSource
    }
    $elapsed = (Get-Date) - $startedAt
    $timeText = if ($elapsed.TotalSeconds -ge 1) { " ($(Format-Elapsed $elapsed))" } else { '' }
    Update-TaskStatus "$Activity$timeText" -Complete -Ok
}

function Get-Sha256([string]$Path) {
    # 返回文件的 SHA-256（小写）
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Format-ByteSize([Int64]$Bytes) {
    # 人性化字节大小（B/KB/MB/GB）
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value /= 1024
        $index++
    }
    return ('{0:N1} {1}' -f $value, $units[$index])
}

function Format-Elapsed([TimeSpan]$Elapsed) {
    # 人性化时长：29s、1m5s、2m，比 mm:ss 补零更直观
    if ($Elapsed.TotalSeconds -ge 60) {
        $minutes = [Math]::Floor($Elapsed.TotalMinutes)
        $seconds = [Math]::Round($Elapsed.TotalSeconds - ($minutes * 60))
        if ($seconds -ge 60) { $minutes++; $seconds = 0 }
        if ($seconds -eq 0) { return "$minutes`m" }
        return "$minutes`m${seconds}s"
    }
    return ('{0}s' -f [Math]::Round($Elapsed.TotalSeconds))
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [hashtable]$Headers = @{},
        [string]$LogSource = 'download'
    )

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $true
    $request.UserAgent = if ($Headers.ContainsKey('User-Agent')) { [string]$Headers['User-Agent'] } else { 'Hermes-Builder' }
    $response = $null
    $input = $null
    $output = $null
    $fileName = [System.IO.Path]::GetFileName(([Uri]$Uri).AbsolutePath)

    try {
        $response = $request.GetResponse()
        $totalBytes = [Int64]$response.ContentLength
        $input = $response.GetResponseStream()
        $output = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 1048576
        $receivedBytes = [Int64]0
        $startedAt = Get-Date

        # 原位动态百分比：通过 .NET 控制台 API 单行刷新（不滚动）
        # 输出重定向或宿主非真实控制台时，Write-InlineStatus 为空操作，
        # 每 5 秒输出一行低频提示
        $lastDraw = $startedAt.AddSeconds(-1)
        $lastFallback = [DateTime]::MinValue
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $receivedBytes += $read
            $now = Get-Date
            if (($now - $lastDraw).TotalMilliseconds -ge 250) {
                $elapsedSeconds = [Math]::Max(($now - $startedAt).TotalSeconds, 0.1)
                $speed = Format-ByteSize ([Int64]($receivedBytes / $elapsedSeconds))
                if ($totalBytes -gt 0) {
                    $percent = [Math]::Min(100, [Math]::Round(($receivedBytes * 100.0) / $totalBytes, 1))
                    $status = "[Hermes] Downloading $fileName  $percent%  $(Format-ByteSize $receivedBytes) / $(Format-ByteSize $totalBytes)  $speed/s"
                }
                else {
                    $status = "[Hermes] Downloading $fileName  $(Format-ByteSize $receivedBytes)  $speed/s"
                }
                $inPlace = Write-InlineStatus $status
                # 仅当原位刷新不可用（输出重定向或非控制台宿主）时才输出兜底行，
                # 保证真实控制台绝不滚动
                if (-not $inPlace -and ($now - $lastFallback).TotalSeconds -ge 5) {
                    Write-Host $status -ForegroundColor Cyan
                    $lastFallback = $now
                }
                $lastDraw = $now
            }
        }
        $completedLine = "[Hermes] $script:SymOk Downloaded ${fileName}: $(Format-ByteSize $receivedBytes)"
        $totalSeconds = [Math]::Max(((Get-Date) - $startedAt).TotalSeconds, 0.1)
        $averageSpeed = Format-ByteSize ([Int64]($receivedBytes / $totalSeconds))
        Write-BuildLog "Downloaded ${fileName}: $(Format-ByteSize $receivedBytes) ($averageSpeed/s)" 'INFO' $LogSource
        Clear-TaskStatusLine
        Write-Host $completedLine -ForegroundColor Green
    }
    catch {
        Write-BuildLog "Download failed for ${fileName}: $($_.Exception.Message)" 'ERROR' $LogSource
        throw
    }
    finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Get-VerifiedDownload {
    # 校验并获取下载文件：缓存命中（SHA-256 一致）直接复用，否则下载到 .part 临时文件，校验通过后原子改名
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [string]$LogSource = 'download'
    )

    $expected = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid SHA-256 for $Uri"
    }

    if (Test-Path -LiteralPath $Destination) {
        if ((Get-Sha256 $Destination) -eq $expected) {
            Write-Info "Cache hit: $([System.IO.Path]::GetFileName($Destination)) (SHA-256 verified, download skipped)" -Source $LogSource
            Write-BuildLog "Using verified cached download: $([System.IO.Path]::GetFileName($Destination))" 'INFO' $LogSource
            return $Destination
        }
        Write-BuildLog "Cached download failed SHA-256 and will be replaced: $([System.IO.Path]::GetFileName($Destination))" 'WARN' $LogSource
        Remove-Item -LiteralPath $Destination -Force
    }

    Ensure-Directory (Split-Path -Parent $Destination) | Out-Null
    $partial = "$Destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-Info -Message "Downloading $Uri" -Source $LogSource
    Invoke-Download -Uri $Uri -Destination $partial -Headers $script:GitHubHeaders -LogSource $LogSource
    if ((Get-Sha256 $partial) -ne $expected) {
        Write-BuildLog "SHA-256 verification failed: $Uri" 'ERROR' $LogSource
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed: $Uri"
    }
    Move-Item -LiteralPath $partial -Destination $Destination
    Write-BuildLog "SHA-256 verified: $([System.IO.Path]::GetFileName($Destination))" 'INFO' $LogSource
    return $Destination
}

function Get-GitHubReleaseAsset {
    # 查询 GitHub 最新正式版发布，按名称模式匹配资产，返回其官方 SHA-256 摘要
    param([string]$Repository, [string]$NamePattern)

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $script:GitHubHeaders
    if ($release.prerelease -or $release.draft) { throw "Unexpected non-stable release returned for $Repository" }
    $asset = $release.assets | Where-Object { $_.name -match $NamePattern } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching $NamePattern in $Repository" }
    $match = [regex]::Match([string]$asset.digest, '^sha256:([0-9a-fA-F]{64})$')
    if (-not $match.Success) { throw "The official $Repository asset lacks a SHA-256 digest: $($asset.name)" }
    return [pscustomobject]@{
        Name = [string]$asset.name
        Uri = [string]$asset.browser_download_url
        Sha256 = $match.Groups[1].Value.ToLowerInvariant()
        Version = [string]$release.tag_name
    }
}

function Expand-ZipTo([string]$Archive, [string]$Destination) {
    # 用系统 tar.exe 解压 ZIP 到目标目录（tar 会校验 ZIP 完整性），解压前清空目标
    Remove-PortableTree $Destination
    Ensure-Directory $Destination | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tar)) { throw "Windows tar.exe is required but was not found: $tar" }
    Invoke-External -FilePath $tar -Arguments @('-xf', $Archive, '-C', $Destination) -LogSource 'extract'
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    # 复制源目录全部内容到目标（含隐藏项）
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source directory is missing: $Source" }
    Ensure-Directory $Destination | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Destination -Recurse -Force
    Write-BuildLog "Copied: $Source -> $Destination" 'INFO' 'fs'
}

function Ensure-BootstrapGit {
    # 确保引导用 Git 可用（cache\bootstrap\git），缺失时下载官方 PortableGit 自解压包安装
    $bootstrapRoot = Join-Path $script:BuildDir 'cache\bootstrap\git'
    $git = Join-Path $bootstrapRoot 'cmd\git.exe'
    if (Test-Path -LiteralPath $git) {
        Write-Info 'Bootstrap Git is already cached; skipping re-download.' -Source 'tools'
        return $git
    }

    $asset = Get-GitHubReleaseAsset -Repository 'git-for-windows/git' -NamePattern '^PortableGit-.*-64-bit\.7z\.exe$'
    $archive = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $asset.Name)
    Get-VerifiedDownload -Uri $asset.Uri -Destination $archive -ExpectedSha256 $asset.Sha256 | Out-Null

    $stage = "$bootstrapRoot.__next"
    Remove-PortableTree $stage
    Ensure-Directory (Split-Path -Parent $bootstrapRoot) | Out-Null
    $result = Start-Process -FilePath $archive -ArgumentList @('-y', "-o$stage") -Wait -PassThru -WindowStyle Hidden
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $stage 'cmd\git.exe'))) {
        Remove-PortableTree $stage
        throw 'PortableGit extraction failed.'
    }
    if (Test-Path -LiteralPath $bootstrapRoot) { Remove-PortableTree $bootstrapRoot }
    Move-Item -LiteralPath $stage -Destination $bootstrapRoot
    return $git
}

function Ensure-BootstrapUv {
    # 确保引导用 uv 可用（cache\bootstrap\uv），缺失时下载官方 zip 提取 uv.exe
    $bootstrapRoot = Join-Path $script:BuildDir 'cache\bootstrap\uv'
    $uv = Join-Path $bootstrapRoot 'uv.exe'
    if (Test-Path -LiteralPath $uv) {
        Write-Info 'Bootstrap uv is already cached; skipping re-download.' -Source 'tools'
        return $uv
    }

    $asset = Get-GitHubReleaseAsset -Repository 'astral-sh/uv' -NamePattern '^uv-x86_64-pc-windows-msvc\.zip$'
    $archive = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $asset.Name)
    Get-VerifiedDownload -Uri $asset.Uri -Destination $archive -ExpectedSha256 $asset.Sha256 | Out-Null
    $extract = Join-Path $script:BuildDir 'cache\bootstrap\uv-extract'
    Expand-ZipTo $archive $extract
    $found = Get-ChildItem -LiteralPath $extract -Recurse -File -Filter 'uv.exe' | Select-Object -First 1
    if (-not $found) { throw 'The official uv archive did not contain uv.exe.' }
    Remove-PortableTree $bootstrapRoot
    Ensure-Directory $bootstrapRoot | Out-Null
    Copy-Item -LiteralPath $found.FullName -Destination $uv -Force
    $uvx = Join-Path (Split-Path -Parent $found.FullName) 'uvx.exe'
    if (Test-Path -LiteralPath $uvx) { Copy-Item -LiteralPath $uvx -Destination (Join-Path $bootstrapRoot 'uvx.exe') -Force }
    Remove-PortableTree $extract
    return $uv
}

function Get-LatestStableTag {
    # 查询 Hermes 最新正式版 tag（-Tag 已在调用方处理）
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/NousResearch/hermes-agent/releases/latest' -Headers $script:GitHubHeaders
    $releaseTag = ([string]$release.tag_name).Trim()
    if ($release.prerelease -or $release.draft -or $releaseTag -notmatch '^v\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?$') {
        throw "GitHub did not return a valid stable Hermes release tag: $releaseTag"
    }
    return $releaseTag
}

function Get-LatestScriptRelease {
    # 查询本仓库最新正式版发布；网络/API 异常时抛错由调用方处理
    $uri = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/releases/latest"
    $release = Invoke-RestMethod -Uri $uri -Headers $script:GitHubHeaders -TimeoutSec 20
    if ($release.prerelease -or $release.draft) { throw "Unexpected non-stable release: $($release.tag_name)" }
    return $release
}

function Compare-ScriptVersion([string]$LatestTag) {
    # 远程 tag 有效且高于当前脚本版本时返回 $true，否则 $false
    if ($LatestTag -notmatch '^v\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?$') { return $false }
    try {
        $current = [version]((($script:ScriptVersion -replace '^v', '') -split '-')[0])
        $latest = [version]((($LatestTag -replace '^v', '') -split '-')[0])
    }
    catch { return $false }
    return $latest -gt $current
}

function Invoke-ScriptUpdateCheck {
    # 强制脚本自更新检查（每次运行最先执行）：
    #   返回 $false = 已是最新，可继续流程
    #   返回 $true  = 网络异常 / 更新成功待重跑 / 更新失败，必须阻止流程
    $release = $null
    try {
        $release = Get-LatestScriptRelease
    }
    catch {
        if ($_.Exception.Message -match '404') {
            Write-Host "[Hermes] $script:SymErr No release found in $script:RepoOwner/$script:RepoName. Publish a release first (e.g. tag v1.0.0), then re-run." -ForegroundColor Red
        }
        else {
        Write-Host "[Hermes] $script:SymErr Script update check failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Verify your network or proxy, then re-run the script.' -ForegroundColor Gray
        }
        return $true
    }

    if (-not (Compare-ScriptVersion ([string]$release.tag_name))) {
        Write-Host "[Hermes] $script:SymOk Script is up to date ($script:ScriptVersion)." -ForegroundColor Green
        return $false
    }

    Write-Host "[Hermes] $script:SymInfo New script version $($release.tag_name) is available (current $script:ScriptVersion). Updating..." -ForegroundColor Cyan
    $asset = $release.assets | Where-Object { $_.name -eq 'Hermit-Hermes.ps1' } | Select-Object -First 1
    if (-not $asset) {
        Write-Host "[Hermes] $script:SymErr Release $($release.tag_name) is incomplete (missing the Hermit-Hermes.ps1 asset); update aborted." -ForegroundColor Red
        return $true
    }
    $digestMatch = [regex]::Match([string]$asset.digest, '^sha256:([0-9a-fA-F]{64})$')
    if (-not $digestMatch.Success) {
        Write-Host "[Hermes] $script:SymErr Release $($release.tag_name) asset lacks an official SHA-256 digest; update aborted." -ForegroundColor Red
        return $true
    }
    $expected = $digestMatch.Groups[1].Value.ToLowerInvariant()

    $updateRoot = Join-Path $env:TEMP "Hermit-Hermes-update-$PID"
    Ensure-Directory $updateRoot | Out-Null
    $tmpScript = Join-Path $updateRoot 'Hermit-Hermes.ps1'
    try {
        Invoke-Download -Uri $asset.browser_download_url -Destination $tmpScript -Headers $script:GitHubHeaders -LogSource 'self-update'

        $actual = (Get-FileHash -LiteralPath $tmpScript -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            throw 'SHA-256 verification failed; the downloaded script was not applied.'
        }

        # 运行中的脚本已被完整读入内存，Windows 下可直接覆盖自身
        Copy-Item -LiteralPath $tmpScript -Destination $script:SelfPath -Force
    }
    catch {
        Write-Host "[Hermes] $script:SymErr Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  The current script was left unchanged. You can manually replace it with: $tmpScript" -ForegroundColor Gray
        return $true
    }
    finally {
        Remove-Item -LiteralPath $updateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[Hermes] $script:SymOk Updated to $($release.tag_name). Please re-run the script to continue." -ForegroundColor Green
    return $true
}
function Test-DesktopSupported([string]$Tag) {
    # Hermes Desktop（Electron 桌面端）自 v2026.6.5 起随上游引入；
    # 更早版本只有 web/ui-tui，无法打包 Hermes.exe，构建直接拦截
    $min = @(2026, 6, 5)
    $parts = @((($Tag -replace '^v', '') -split '[.\-]') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    if ($parts.Count -lt 3) { return $false }
    for ($i = 0; $i -lt $min.Count; $i++) {
        $part = if ($i -lt $parts.Count) { $parts[$i] } else { 0 }
        if ($part -gt $min[$i]) { return $true }
        if ($part -lt $min[$i]) { return $false }
    }
    return $true
}

function Test-HermesTagExists {
    # 向上游查询 -Tag 指定的版本是否存在（404 = 不存在；网络异常返回 $null 不拦截）
    param([string]$Tag)
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/repos/NousResearch/hermes-agent/releases/tags/$Tag" -Headers $script:GitHubHeaders -TimeoutSec 15
        return $true
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 404) { return $false }
        return $null
    }
}

function Get-HermesReleases {
    # 拉取 Hermes 官方正式版列表（过滤草稿/预发布/不合规 tag），按发布时间倒序
    param([int]$MaxCount = 0)  # 0 表示返回全部
    $releases = New-Object System.Collections.Generic.List[object]
    $page = 1
    while ($true) {
        $batch = Invoke-RestMethod -Uri "https://api.github.com/repos/NousResearch/hermes-agent/releases?per_page=100&page=$page" -Headers $script:GitHubHeaders -TimeoutSec 15
        if (-not $batch) { break }
        foreach ($release in $batch) {
            if ($release.draft -or $release.prerelease) { continue }
            $tag = ([string]$release.tag_name).Trim()
            if ($tag -notmatch '^v\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?$') { continue }
            $releases.Add($release)
        }
        if ($batch.Count -lt 100) { break }
        if ($MaxCount -gt 0 -and $releases.Count -ge $MaxCount) { break }
        $page++
    }
    $sorted = @($releases | Sort-Object -Property @{ Expression = { try { [datetime]$_.published_at } catch { [datetime]::MinValue } } } -Descending)
    if ($MaxCount -gt 0) { $sorted = @($sorted | Select-Object -First $MaxCount) }
    return ,$sorted
}

function Show-AvailableVersions {
    # -Tag（空）/ -Tag listall：列出可安装的正式版本，标注最新版与当前已安装版本
    param([switch]$All)
    $limit = if ($All) { 0 } else { 10 }
    $releases = Get-HermesReleases -MaxCount $limit
    if (-not $releases) { throw 'No Hermes releases found - check your network or proxy.' }

    # 读取当前安装版本（读取失败不影响列表展示）
    $installedTag = ''
    $installedPath = Join-Path $script:HermesDir 'manifests\installed.json'
    if (Test-Path -LiteralPath $installedPath) {
        try {
            $installedTag = ([string](Get-Content -LiteralPath $installedPath -Raw | ConvertFrom-Json).releaseTag).Trim()
        }
        catch { $installedTag = '' }
    }

    # 仅列出支持 Hermes Desktop 的版本（桌面端自 v2026.6.5 起提供）
    $releases = @($releases | Where-Object { Test-DesktopSupported ([string]$_.tag_name).Trim() })
    if (-not $releases) { throw 'No Hermes releases with Hermes Desktop found.' }
    $latestTag = ([string]$releases[0].tag_name).Trim()
    Write-Host ''
    Write-Host 'Hermes versions available for install:' -ForegroundColor White
    Write-Host ''
    foreach ($release in $releases) {
        $tag = ([string]$release.tag_name).Trim()
        $markers = @()
        if ($tag -eq $latestTag) { $markers += 'latest' }
        if ($installedTag -and $tag -eq $installedTag) { $markers += 'installed' }
        $color = if ($tag -eq $installedTag) { 'Green' } elseif ($tag -eq $latestTag) { 'Cyan' } else { 'White' }
        $line = "  $tag"
        if ($markers.Count) { $line += '  (' + ($markers -join ', ') + ')' }
        Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
    Write-Host 'Older versions (before v2026.6.5) are hidden because they do not include Hermes Desktop.' -ForegroundColor Gray
    Write-Host 'Usage: .\Hermit-Hermes.ps1 -Tag <version>   e.g. -Tag v2026.8.3' -ForegroundColor Gray
    Write-Host ''
}

function Backup-PersonalData {
    # -Backup：把 data\ 下的必要个人数据备份到 Hermes\backups\data-<时间戳>\
    # 只备份白名单项（配置/密钥/数据库/会话/记忆/定时任务/技能/插件等），
    # 缓存、日志、历史快照、junction 链接等可再生或非数据内容一律跳过
    $source = Join-Path $script:HermesDir 'data'
    $backupRoot = Join-Path $script:HermesDir 'backups'
    if (-not (Test-Path -LiteralPath $source)) { throw 'No personal data directory found to back up.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $target = Join-Path $backupRoot "data-$stamp"
    Ensure-Directory $target | Out-Null
    $whitelist = @(
        '.env', 'config.yaml', 'SOUL.md',
        'projects.db', 'state.db', 'state.db-shm', 'state.db-wal', 'kanban.db',
        'gateway_state.json', 'channel_directory.json',
        'sessions', 'memories', 'pending_messages',
        'cron', 'skills', 'desktop-plugins', 'hooks', 'pets',
        'pairing', 'platforms', 'state',
        '.skills_prompt_snapshot.json'
    )
    $count = 0
    foreach ($name in $whitelist) {
        $itemPath = Join-Path $source $name
        if (Test-Path -LiteralPath $itemPath) {
            try {
                Copy-Item -LiteralPath $itemPath -Destination $target -Recurse -Force
                $count++
            }
            catch {
                Write-WarnPortable "Skipped $name (access denied): $($_.Exception.Message)" -Source 'backup'
            }
        }
    }
    if ($count -eq 0) { throw 'No personal data found to back up.' }
    $size = (Get-ChildItem -LiteralPath $target -Recurse -Force | Measure-Object -Property Length -Sum).Sum
    $sizeMb = [Math]::Round($size / 1MB, 1)
    Write-Ok "Personal data backed up ($count items, $sizeMb MB): $target" -Source 'backup'
}

function Get-ReleaseWorktree {
    # 将指定 tag 的源码拉取到私有裸缓存，并在 source 下检出工作树
    param([string]$GitExe, [string]$ReleaseTag)
    Write-Info "Fetching Hermes source for $ReleaseTag..." -Source 'git'

    # 私有 bare 仓库缓存：增量复用，避免每次全量克隆
    $bare = Join-Path $script:BuildDir 'cache\sources\hermes-agent.git'
    if (-not (Test-Path -LiteralPath (Join-Path $bare 'HEAD'))) {
        Ensure-Directory (Split-Path -Parent $bare) | Out-Null
        Invoke-External -FilePath $GitExe -Arguments @('-c', 'advice.defaultBranchName=false', 'init', '--bare', '--quiet', $bare) -LogSource 'git'
        Invoke-External -FilePath $GitExe -Arguments @('--git-dir', $bare, 'remote', 'add', 'origin', $script:SourceRepo) -LogSource 'git'
    }

    # 只拉取该 tag 的提交与树对象（--filter=blob:none 跳过文件内容，更新时省大量下载）
    Invoke-External -FilePath $GitExe -Arguments @('--git-dir', $bare, 'fetch', '--quiet', '--filter=blob:none', '--prune', 'origin', "refs/tags/${ReleaseTag}:refs/tags/${ReleaseTag}") -Quiet -Activity 'Fetching Hermes source' -LogSource 'git'
    # 解析 tag 指向的提交哈希，作为构建的精确版本依据
    $commit = (& $GitExe --git-dir=$bare rev-parse --verify "refs/tags/$ReleaseTag`^{commit}").Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') { throw "Could not resolve release commit for $ReleaseTag" }

    # 从 bare 缓存检出该提交的工作树，作为构建现场（含全部文件内容）
    $worktree = Join-Path $script:BuildDir 'source'
    Remove-PortableTree $worktree
    Ensure-Directory (Split-Path -Parent $worktree) | Out-Null
    Invoke-External -FilePath $GitExe -Arguments @('--git-dir', $bare, 'worktree', 'prune') -LogSource 'git'
    Invoke-External -FilePath $GitExe -Arguments @('--git-dir', $bare, 'worktree', 'add', '--quiet', '--detach', $worktree, $commit) -LogSource 'git'
    Write-Ok "Hermes source ready (commit $commit)" -Source 'git'
    return [pscustomobject]@{ Path = $worktree; Commit = $commit; Tag = $ReleaseTag }
}

function Get-RequiredNodeMajor([string]$Source) {
    # 优先读桌面端 engines 标注（上游各版本均无 .nvmrc），
    # 从版本约束中取最大主版本（如 "^20.19.0 || >=22.12.0" -> 22）
    $desktopPkg = Join-Path $Source 'apps\desktop\package.json'
    if (Test-Path -LiteralPath $desktopPkg) {
        try {
            $pkg = [System.IO.File]::ReadAllText($desktopPkg, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            if ($pkg.engines -and $pkg.engines.node) {
                $spec = [string]$pkg.engines.node
                $majors = @([regex]::Matches($spec, '(?:\^|>=|~)?v?([0-9]+)\.') | ForEach-Object { [int]$_.Groups[1].Value })
                if ($majors.Count -gt 0) { return ($majors | Sort-Object -Descending | Select-Object -First 1) }
            }
        }
        catch { }
    }
    $nvmrc = Join-Path $Source '.nvmrc'
    if (Test-Path -LiteralPath $nvmrc) {
        $value = (Get-Content -LiteralPath $nvmrc -Raw).Trim()
        if ($value -match '^v?(\d+)$') { return [int]$Matches[1] }
    }
    # 上游若移除 engines 标注，此兜底值刻意保持保守
    return 22
}

function Get-RequiredPythonVersion([string]$Source) {
    # 从 pyproject.toml 的 requires-python 解析出创建 venv 用的 Python 主版本，
    # 取下限的 minor 版本（如 ">=3.11,<3.14" -> 3.11），上游改范围自动跟随
    $pyproject = Join-Path $Source 'pyproject.toml'
    if (Test-Path -LiteralPath $pyproject) {
        try {
            $text = [System.IO.File]::ReadAllText($pyproject, [System.Text.UTF8Encoding]::new($false))
            $match = [regex]::Match($text, '(?m)^\s*requires-python\s*=\s*["'']?([^"''\r\n]+)["'']?\s*$')
            if ($match.Success) {
                $versionMatch = [regex]::Match($match.Groups[1].Value, '([0-9]+)\.([0-9]+)')
                if ($versionMatch.Success) {
                    return ('{0}.{1}' -f $versionMatch.Groups[1].Value, $versionMatch.Groups[2].Value)
                }
            }
        }
        catch { }
    }
    # 上游若移除 requires-python，退回当前官方支持的保守版本
    return '3.11'
}

function Get-RequiredCamofoxSpec([string]$Source) {
    # camofox-browser 上游不锁进 package.json（显式可选），但官方安装脚本
    # scripts/install.ps1（及 install.sh）固定了附带版本；构建时源码已完整检出，
    # 直接从当前版本读取，找不到再退回保守版本
    foreach ($installScript in @(
        (Join-Path $Source 'scripts\install.ps1'),
        (Join-Path $Source 'scripts\install.sh')
    )) {
        if (-not (Test-Path -LiteralPath $installScript)) { continue }
        $installText = [System.IO.File]::ReadAllText($installScript, [System.Text.UTF8Encoding]::new($false))
        $match = [regex]::Match($installText, '@askjo/camofox-browser@([^\s"`]+)')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return '^1.5.2'
}

function Install-NodeRuntime {
    # 安装指定主版本的 Node 到目标目录（.nvmrc 版本未变时直接复制当前安装）
    param([int]$Major, [string]$Destination)

    # Node 复用：.nvmrc 主版本未变时直接从当前安装复制，省下载与解压约 10~30 秒。
    # node 是自包含二进制目录，无绝对路径依赖，复制与解压等价且更快。
    $currentNode = Join-Path $script:HermesDir 'runtime\node\node.exe'
    if (Test-Path -LiteralPath $currentNode) {
        $currentMajor = $null
        try {
            $versionLine = (& $currentNode --version 2>$null | Select-Object -First 1)
            if ($versionLine -match '^v?(\d+)') { $currentMajor = [int]$Matches[1] }
        }
        catch { }
        if ($currentMajor -eq $Major) {
            Write-Info "Node $Major unchanged; copying from the current install (saves download+extract)" -Source 'node'
            Remove-PortableTree $Destination
            Copy-DirectoryContents (Join-Path $script:HermesDir 'runtime\node') $Destination
            if (-not (Test-Path -LiteralPath (Join-Path $Destination 'node.exe'))) {
                throw "Copied Node is missing node.exe: $Destination"
            }
            Write-Ok "Node $Major reused" -Source 'node'
            return
        }
        if ($null -ne $currentMajor) {
            Write-Info "Node version changed $currentMajor -> $Major; downloading" -Source 'node'
        }
    }

    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
    $release = $index | Where-Object { $_.version -match "^v$Major\." } | Select-Object -First 1
    if (-not $release) { throw "No current Node $Major Windows release was found." }
    $version = [string]$release.version
    $file = "node-$version-win-x64.zip"
    $checksumText = (Invoke-WebRequest -Uri "https://nodejs.org/dist/$version/SHASUMS256.txt" -UseBasicParsing).Content
    $line = $checksumText -split "`n" | Where-Object { $_ -match "\s$file$" } | Select-Object -First 1
    $match = [regex]::Match([string]$line, '^([0-9a-fA-F]{64})\s+')
    if (-not $match.Success) { throw "Node did not publish a SHA-256 for $file" }
    $archive = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $file)
    Get-VerifiedDownload -Uri "https://nodejs.org/dist/$version/$file" -Destination $archive -ExpectedSha256 $match.Groups[1].Value | Out-Null

    $extract = Join-Path $script:BuildDir 'node-extract'
    Expand-ZipTo $archive $extract
    $nodeRoot = Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe') } | Select-Object -First 1
    if (-not $nodeRoot) { throw 'The official Node archive did not contain node.exe.' }
    Remove-PortableTree $Destination
    Move-Item -LiteralPath $nodeRoot.FullName -Destination $Destination
    Remove-PortableTree $extract
}

function Test-PrivateToolsCurrent {
    # 当已安装的私有工具已是最新版本时返回 $true，Install-PrivateTools 可跳过重装
    # 检测基于摘要对比：用缓存下载 zip 的 SHA-256 与 GitHub 发布的最新
    # 资产摘要比对，无需解析版本字符串
    $current = Join-Path $script:HermesDir 'tools'
    $required = @(
        (Join-Path $current 'ripgrep\rg.exe'),
        (Join-Path $current 'ffmpeg\ffmpeg.exe'),
        (Join-Path $current 'ffmpeg\ffprobe.exe'),
        (Join-Path $current 'ffmpeg\ffplay.exe')
    )
    if (@($required | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) { return $false }

    try {
        $rgAsset = Get-GitHubReleaseAsset -Repository 'BurntSushi/ripgrep' -NamePattern '^ripgrep-.*-x86_64-pc-windows-msvc\.zip$'
        $rgCache = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $rgAsset.Name)
        # 缓存 zip 缺失时无法比对摘要，保守判定为需重装，避免旧版工具被误判为最新
        if (-not (Test-Path -LiteralPath $rgCache)) { return $false }
        if ((Get-Sha256 $rgCache) -ne $rgAsset.Sha256) { return $false }

        # FFmpeg 锁定 8.1 分支（与 Install-PrivateTools 保持一致），latest 命名保证该分支持续更新
        $ffmpegAsset = Get-GitHubReleaseAsset -Repository 'BtbN/FFmpeg-Builds' -NamePattern '^ffmpeg-n8\.1-latest-win64-gpl-8\.1\.zip$'
        $ffmpegCache = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $ffmpegAsset.Name)
        # 同上：缓存缺失时保守判定为需重装
        if (-not (Test-Path -LiteralPath $ffmpegCache)) { return $false }
        if ((Get-Sha256 $ffmpegCache) -ne $ffmpegAsset.Sha256) { return $false }
    }
    catch {
        # API 或摘要查询失败：保守处理，按正常流程重新安装
        return $false
    }
    return $true
}

function Install-PrivateTools {
    # 安装私有工具（ripgrep/FFmpeg）到 tools\：先校验是否已最新，否则下载、解压、原子换名
    if (Test-PrivateToolsCurrent) {
        Write-Info 'Private tools are already the latest versions; skipping re-install.' -Source 'tools'
        return
    }
    $next = Join-Path $script:BuildDir 'tools-candidate'
    Remove-PortableTree $next
    Ensure-Directory $next | Out-Null

    $rgAsset = Get-GitHubReleaseAsset -Repository 'BurntSushi/ripgrep' -NamePattern '^ripgrep-.*-x86_64-pc-windows-msvc\.zip$'
    $rgArchive = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $rgAsset.Name)
    Get-VerifiedDownload -Uri $rgAsset.Uri -Destination $rgArchive -ExpectedSha256 $rgAsset.Sha256 | Out-Null
    $rgExtract = Join-Path $script:BuildDir 'rg-extract'
    Expand-ZipTo $rgArchive $rgExtract
    $rg = Get-ChildItem -LiteralPath $rgExtract -Recurse -File -Filter 'rg.exe' | Select-Object -First 1
    if (-not $rg) { throw 'The official ripgrep archive did not contain rg.exe.' }
    Ensure-Directory (Join-Path $next 'ripgrep') | Out-Null
    Copy-Item -LiteralPath $rg.FullName -Destination (Join-Path $next 'ripgrep\rg.exe') -Force
    Remove-PortableTree $rgExtract

    # BtbN 发布带签名的 GitHub Release 资产，选择 Windows x64、
    # FFmpeg 8.1 发布分支的 GPL 静态构建，并校验 GitHub 的 SHA-256。
    # 刻意锁定 n8.1 分支：BtbN 的 latest 命名保证该分支持续更新；
    # 如需升级到更高分支，需同步修改此处与 Test-PrivateToolsCurrent 的名称模式
    $ffmpegAsset = Get-GitHubReleaseAsset -Repository 'BtbN/FFmpeg-Builds' -NamePattern '^ffmpeg-n8\.1-latest-win64-gpl-8\.1\.zip$'
    $ffmpegArchive = Join-Path $script:BuildDir (Join-Path 'cache\downloads' $ffmpegAsset.Name)
    Get-VerifiedDownload -Uri $ffmpegAsset.Uri -Destination $ffmpegArchive -ExpectedSha256 $ffmpegAsset.Sha256 | Out-Null
    $ffmpegExtract = Join-Path $script:BuildDir 'ffmpeg-extract'
    Expand-ZipTo $ffmpegArchive $ffmpegExtract
    $ffmpeg = Get-ChildItem -LiteralPath $ffmpegExtract -Recurse -File -Filter 'ffmpeg.exe' | Select-Object -First 1
    if (-not $ffmpeg) { throw 'The FFmpeg archive did not contain ffmpeg.exe.' }
    $bin = Split-Path -Parent $ffmpeg.FullName
    Ensure-Directory (Join-Path $next 'ffmpeg') | Out-Null
    foreach ($name in @('ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe')) {
        $file = Join-Path $bin $name
        if (-not (Test-Path -LiteralPath $file)) { throw "The FFmpeg archive did not contain $name." }
        Copy-Item -LiteralPath $file -Destination (Join-Path $next (Join-Path 'ffmpeg' $name)) -Force
    }
    Remove-PortableTree $ffmpegExtract

    $current = Join-Path $script:HermesDir 'tools'
    $previous = Join-Path $script:BuildDir 'tools-candidate.old'
    Remove-PortableTree $previous
    if (Test-Path -LiteralPath $current) { Move-Item -LiteralPath $current -Destination $previous }
    try {
        Move-Item -LiteralPath $next -Destination $current
    }
    catch {
        if (-not (Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $previous)) {
            Move-Item -LiteralPath $previous -Destination $current
        }
        throw
    }
    Remove-PortableTree $previous
}

function Get-PortableEnvironment {
    # 构建/运行 Hermes 用的完整私有环境（PATH 前缀 + 全部私有目录变量），与系统环境完全隔离
    param([string]$Runtime, [string]$Data, [string]$NodeCache)

    $systemRoot = $env:SystemRoot
    # PATH 前缀按「私有优先」排列：Hermes 自带工具在前，系统目录兜底在后，
    # 且不包含系统原有 PATH——构建/运行时的任何命令解析都只在私有环境内进行
    $entries = @(
        (Join-Path $script:HermesDir 'tools\ripgrep'),
        (Join-Path $script:HermesDir 'tools\ffmpeg'),
        (Join-Path $Runtime 'agent\venv\Scripts'),
        (Join-Path $Runtime 'uv\bin'),
        (Join-Path $Runtime 'node'),
        (Join-Path $Runtime 'node\node_modules\.bin'),
        (Join-Path $Runtime 'git\cmd'),
        (Join-Path $Runtime 'git\bin'),
        (Join-Path $systemRoot 'System32'),
        (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0'),
        $systemRoot
    )
    return @{
        PATH = ($entries -join ';')
        HERMES_HOME = $Data
        HERMES_GIT_BASH_PATH = (Join-Path $Runtime 'git\bin\bash.exe')
        HOME = (Join-Path $Data 'home')
        USERPROFILE = (Join-Path $Data 'home')
        APPDATA = (Join-Path $Data 'appdata-roaming')
        LOCALAPPDATA = (Join-Path $Data 'appdata-local')
        HERMES_DESKTOP_USER_DATA_DIR = (Join-Path $Data 'desktop')
        UV_CACHE_DIR = (Join-Path $script:BuildDir 'cache\uv')
        UV_PYTHON_INSTALL_DIR = (Join-Path $Runtime 'python')
        UV_TOOL_DIR = (Join-Path $Runtime 'uv\tools')
        UV_TOOL_BIN_DIR = (Join-Path $Runtime 'uv\bin')
        UV_INSTALL_DIR = (Join-Path $Runtime 'uv\bin')
        UV_NO_MODIFY_PATH = '1'
        NPM_CONFIG_CACHE = $NodeCache
        NPM_CONFIG_PREFIX = (Join-Path $Runtime 'node')
        PLAYWRIGHT_BROWSERS_PATH = (Join-Path $Runtime 'browsers\playwright')
        ELECTRON_CACHE = (Join-Path $script:BuildDir 'cache\electron')
        ELECTRON_BUILDER_CACHE = (Join-Path $script:BuildDir 'cache\electron-builder')
        TEMP = (Join-Path $script:BuildDir 'cache\tmp')
        TMP = (Join-Path $script:BuildDir 'cache\tmp')
    }
}

function Install-PrivatePlaywrightChromium {
    param(
        [Parameter(Mandatory)][string]$Agent,
        [Parameter(Mandatory)][hashtable]$Environment,
        [string]$Runtime = ''
    )

    # Playwright 随 npm 包发布其所需浏览器版本元数据，
    # 读取该元数据后直接下载对应的 Chrome-for-Testing 归档，
    # 避免使用 Playwright 安装器进程（该进程在 Windows 上报告完成后可能挂起）
    # playwright-core 可能位于根 node_modules（旧布局）、apps\desktop
    # 工作区嵌套目录（v2026.7.30 起），或全局 camofox-browser 的嵌套依赖
    # （老版本 agent 依赖树不含 playwright-core 时的唯一来源），
    # 因此在候选位置查找，找不到再做有界递归兜底；
    # 整个运行时都没有时返回 $false（与上游该版本一致时跳过，不视为构建失败）
    $metadataPath = $null
    $candidates = @(
        (Join-Path $Agent 'node_modules\playwright-core\browsers.json'),
        (Join-Path $Agent 'apps\desktop\node_modules\playwright-core\browsers.json')
    )
    if ($Runtime) {
        $candidates += (Join-Path $Runtime 'node\node_modules\@askjo\camofox-browser\node_modules\playwright-core\browsers.json')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { $metadataPath = $candidate; break }
    }
    if (-not $metadataPath) {
        $searchRoots = @($Agent)
        if ($Runtime -and -not [string]::Equals($Runtime, $Agent, [System.StringComparison]::OrdinalIgnoreCase)) {
            $searchRoots += $Runtime
        }
        foreach ($root in $searchRoots) {
            $fallback = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 5 -Filter 'playwright-core' -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'browsers.json') } |
                Select-Object -First 1
            if ($fallback) { $metadataPath = Join-Path $fallback.FullName 'browsers.json'; break }
        }
    }
    if (-not $metadataPath) {
        return $false
    }
    # 用 UTF-8 显式读取：browsers.json 是官方产物，可能含非 ASCII 字符
    $metadata = [System.IO.File]::ReadAllText($metadataPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $spec = $metadata.browsers | Where-Object { $_.name -eq 'chromium' } | Select-Object -First 1
    if (-not $spec) { throw 'Playwright metadata does not define Chromium.' }

    $revision = [string]$spec.revision
    $version = [string]$spec.browserVersion
    if ($revision -notmatch '^\d+$' -or $version -notmatch '^\d+(\.\d+){3}$') {
        throw "Unsupported Playwright Chromium metadata (revision='$revision', version='$version')."
    }

    $browserDirectory = Join-Path $Environment.PLAYWRIGHT_BROWSERS_PATH "chromium-$revision"
    $chrome = Join-Path $browserDirectory 'chrome-win64\chrome.exe'
    if (Test-Path -LiteralPath $chrome) {
        Write-Info "Playwright Chromium $version is already installed; skipping download." -Source 'chromium'
        return $true
    }

    $archive = Join-Path $script:BuildDir "cache\downloads\playwright-chromium-$revision-$version-win64.zip"
    if (-not (Test-Path -LiteralPath $archive)) {
        Ensure-Directory (Split-Path -Parent $archive) | Out-Null
        Write-Info -Message "Downloading Playwright Chromium $version" -Source 'download'
        Invoke-Download -Uri "https://cdn.playwright.dev/builds/cft/$version/win64/chrome-win64.zip" -Destination $archive -LogSource 'download'
    }

    # tar 解压时会校验 ZIP，最后的 chrome.exe 检查
    # 可防止不完整或错误的归档被接受
    Expand-ZipTo -Archive $archive -Destination $browserDirectory
    if (-not (Test-Path -LiteralPath $chrome)) {
        throw "Chromium archive did not contain the expected executable: $chrome"
    }
    [System.IO.File]::WriteAllText((Join-Path $browserDirectory 'INSTALLATION_COMPLETE'), '')
    return $true
}

function Install-AgentRuntime {
    param([string]$Source, [string]$Runtime, [string]$BootstrapUv, [string]$BootstrapGit)

    $agent = Join-Path $Runtime 'agent'
    Copy-DirectoryContents $Source $agent
    # 运行时不能是 Git 检出：所有更新由本构建器的私有裸缓存管理，
    # 绝不使用 Hermes 应用内更新器
    $agentGit = Join-Path $agent '.git'
    if (Test-Path -LiteralPath $agentGit) { Remove-Item -LiteralPath $agentGit -Force -ErrorAction Stop }

    $runtimeUvDirectory = Join-Path $Runtime 'uv\bin'
    Ensure-Directory $runtimeUvDirectory | Out-Null
    $runtimeUv = Join-Path $runtimeUvDirectory 'uv.exe'
    Copy-Item -LiteralPath $BootstrapUv -Destination $runtimeUv -Force
    $bootstrapUvx = Join-Path (Split-Path -Parent $BootstrapUv) 'uvx.exe'
    if (Test-Path -LiteralPath $bootstrapUvx) {
        Copy-Item -LiteralPath $bootstrapUvx -Destination (Join-Path $runtimeUvDirectory 'uvx.exe') -Force
    }
    if (-not (Test-Path -LiteralPath $runtimeUv)) { throw "Failed to stage private uv.exe: $runtimeUv" }
    Copy-DirectoryContents (Split-Path -Parent (Split-Path -Parent $BootstrapGit)) (Join-Path $Runtime 'git')

    $nodeMajor = Get-RequiredNodeMajor $Source
    Install-NodeRuntime -Major $nodeMajor -Destination (Join-Path $Runtime 'node')
    $environment = Get-PortableEnvironment -Runtime $Runtime -Data (Join-Path $script:HermesDir 'data') -NodeCache (Join-Path $script:BuildDir 'cache\npm')
    foreach ($path in @($environment.UV_CACHE_DIR, $environment.NPM_CONFIG_CACHE, $environment.PLAYWRIGHT_BROWSERS_PATH, $environment.TEMP, $environment.APPDATA, $environment.LOCALAPPDATA, $environment.HOME)) { Ensure-Directory $path | Out-Null }

    $uv = Join-Path $Runtime 'uv\bin\uv.exe'
    $pythonVersion = Get-RequiredPythonVersion -Source $Source
    Invoke-External -FilePath $uv -Arguments @('python', 'install', $pythonVersion) -WorkingDirectory $agent -Environment $environment -Quiet -Activity "Installing bundled Python $pythonVersion" -LogSource 'uv'
    New-StandardPortableVenv -Runtime $Runtime -Agent $agent -Environment $environment -SkipSync

    # 并行阶段：uv sync（Python 依赖）与 npm ci（Node 依赖）互不依赖，
    # 并发执行可节省约一分钟
    $npm = Join-Path $Runtime 'node\npm.cmd'
    $syncEnvironment = @{}
    foreach ($key in $environment.Keys) { $syncEnvironment[$key] = $environment[$key] }
    $syncEnvironment.VIRTUAL_ENV = (Join-Path $agent 'venv')
    Invoke-ExternalParallel -Commands @(
        @{
            FilePath = $uv
            Arguments = @('sync', '--active', '--locked', '--extra', 'all')
            WorkingDirectory = $agent
            Activity = 'Installing Agent Python dependencies'
        },
        @{
            FilePath = $npm
            Arguments = @('ci', '--no-audit', '--no-fund')
            WorkingDirectory = $agent
            Activity = 'Installing Agent Node dependencies'
        }
    ) -Environment $syncEnvironment -Activity 'Installing Agent dependencies' -LogSource 'parallel'

    Invoke-External -FilePath (Join-Path $agent 'venv\Scripts\python.exe') -Arguments @('-c', 'import hermes_cli, dotenv, openai, rich, prompt_toolkit') -WorkingDirectory $agent -Environment $environment -Quiet -Activity 'Verifying Agent Python modules' -LogSource 'verify'
    # agent-browser 的版本范围从源码 package.json 读取，随上游同步
    # camofox-browser 是官方安装器默认附带的反检测浏览器（Camoufox-based
    # Firefox，jo-inc/camofox-browser）：可选启用，运行时设置 CAMOFOX_URL
    # 才生效；版本从当前版本的官方安装脚本动态读取
    $agentBrowserSpec = 'agent-browser'
    $rootPkg = Join-Path $Source 'package.json'
    if (Test-Path -LiteralPath $rootPkg) {
        $pkg = [System.IO.File]::ReadAllText($rootPkg, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $depsProp = $pkg.PSObject.Properties['dependencies']
        $pkgDeps = if ($depsProp) { $depsProp.Value } else { $null }
        if ($pkgDeps -and $pkgDeps.PSObject.Properties['agent-browser']) {
            $agentBrowserSpec = 'agent-browser@' + [string]$pkgDeps.'agent-browser'
        }
    }
    $camofoxSpec = Get-RequiredCamofoxSpec -Source $Source
    Invoke-External -FilePath $npm -Arguments @('install', '-g', '--silent', '--ignore-scripts', $agentBrowserSpec, ("@askjo/camofox-browser@" + $camofoxSpec)) -WorkingDirectory $agent -Environment $environment -Quiet -Activity 'Installing bundled browser tools' -LogSource 'npm-agent'
    # agent-browser 默认把 Chrome 存放在真实 Windows 用户目录下，
    # 改为在私有目录内准备匹配的 Playwright Chromium；
    # 整个运行时无 playwright-core（如上游该版本不含浏览器工具）时跳过并警告
    $playwrightReady = Install-PrivatePlaywrightChromium -Agent $agent -Environment $environment -Runtime $Runtime
    if ($playwrightReady) {
        $chromium = Get-ChildItem -LiteralPath $environment.PLAYWRIGHT_BROWSERS_PATH -Recurse -File -Filter 'chrome.exe' | Select-Object -First 1
        if (-not $chromium) { throw "Playwright Chromium was not installed under $($environment.PLAYWRIGHT_BROWSERS_PATH)" }
    }
    else {
        Write-WarnPortable 'Playwright metadata not found under runtime; skipping Chromium install. Browser tools will be unavailable unless a system Chrome is present.' -Source 'chromium'
    }
}

function Get-PortableBootstrap {
    # 便携环境引导代码：ESM 变体（新版 dist\electron-main.mjs）与
    # CJS 变体（旧版 electron\main.cjs）逻辑一致，仅模块加载方式不同。
    # 引导代码自包含（仅使用 process 与 fs），内联到主入口顶部后随模块
    # 一起执行，不依赖任何额外文件。
    param([switch]$CommonJS)
    $bootstrap = @'
// Hermit-Hermes 便携环境引导
// 作为主入口文件的第一个语句引入，总是先于其它模块或应用逻辑执行
// 即使直接启动 Hermes.exe 也保持隔离
// 环境变量与旧启动器（Start-Hermes.cmd）及 Get-PortableEnvironment 一致
// 总是强制便携根目录，同时覆盖环境中继承的真实用户 HERMES_HOME（如官方安装）


var __hhx = process.execPath.replace(/\\/g, "/");
var __hhp = __hhx.split("/");
__hhp.pop(); __hhp.pop();
var __hroot = __hhp.join("/");
var __hdata = __hroot + "/data";
var __hrun = __hroot + "/runtime";
process.env.HERMES_HOME = __hdata;
process.env.HERMES_DESKTOP_HERMES_ROOT = __hrun + "/agent";
process.env.HERMES_DESKTOP_PYTHON = __hrun + "/agent/venv/Scripts/python.exe";
process.env.HERMES_GIT_BASH_PATH = __hrun + "/git/bin/bash.exe";
process.env.HERMES_DESKTOP_USER_DATA_DIR = __hdata + "/desktop";
process.env.HOME = __hdata + "/home";
process.env.USERPROFILE = __hdata + "/home";
process.env.APPDATA = __hdata + "/appdata-roaming";
process.env.LOCALAPPDATA = __hdata + "/appdata-local";
process.env.UV_CACHE_DIR = __hroot + "/cache/uv";
process.env.UV_PYTHON_INSTALL_DIR = __hrun + "/python";
process.env.UV_TOOL_DIR = __hrun + "/uv/tools";
process.env.UV_TOOL_BIN_DIR = __hrun + "/uv/bin";
process.env.UV_INSTALL_DIR = __hrun + "/uv/bin";
process.env.UV_NO_MODIFY_PATH = "1";
process.env.NPM_CONFIG_CACHE = __hroot + "/cache/npm";
process.env.PIP_CACHE_DIR = __hroot + "/cache/pip";
process.env.NPM_CONFIG_PREFIX = __hrun + "/node";
process.env.PLAYWRIGHT_BROWSERS_PATH = __hrun + "/browsers/playwright";
process.env.ELECTRON_CACHE = __hroot + "/cache/electron";
process.env.ELECTRON_BUILDER_CACHE = __hroot + "/cache/electron-builder";
process.env.TEMP = __hroot + "/cache/tmp";
process.env.TMP = __hroot + "/cache/tmp";
process.env.PATH = __hroot + "/tools/ripgrep;" + __hroot + "/tools/ffmpeg;" + __hrun + "/agent/venv/Scripts;" + __hrun + "/uv/bin;" + __hrun + "/node;" + __hrun + "/node/node_modules/.bin;" + __hrun + "/git/cmd;" + __hrun + "/git/bin;" + (process.env.SystemRoot || "") + "/System32;" + (process.env.SystemRoot || "") + "/System32/WindowsPowerShell/v1.0;" + (process.env.SystemRoot || "");
// venv 自修复已内联：Hermes 目录移动后，venv 内部（pyvenv.cfg 等）的绝对路径仍指向旧位置
// 检测到不一致时直接在本进程内重定位；修复失败则阻止启动，避免坏环境继续运行

try {
  var __fsmod = await import("node:fs");
  var __cfgtext = __fsmod.readFileSync(__hrun + "/agent/venv/pyvenv.cfg", "utf8");
  var __rootbs = __hroot.replace(/\//g, "\\");
  if (__cfgtext.indexOf(__rootbs) < 0 && __cfgtext.indexOf(__hroot) < 0) {
    // 修复失败即阻止启动：避免 venv 失效后回退到系统环境或产生随机报错
    var __repairError = null;
    try {
      var __basePy = null;
      var __findPy = function(__dir) {
        try {
          var __ents = __fsmod.readdirSync(__dir, { withFileTypes: true });
          for (var __i = 0; __i < __ents.length; __i++) {
            var __ent = __ents[__i];
            if (!__ent.isDirectory()) { continue; }
            if (/^cpython-.*-windows-x86_64-none$/.test(__ent.name)) {
              var __cand = __dir + "/" + __ent.name + "/python.exe";
              try { if (__fsmod.existsSync(__cand)) { return __cand; } } catch (e2) {}
            }
            var __sub = __findPy(__dir + "/" + __ent.name);
            if (__sub) { return __sub; }
          }
        } catch (e2) {}
        return null;
      };
      __basePy = __findPy(__hrun + "/python");
      if (!__basePy) { throw new Error("bundled CPython is missing"); }
      var __basePyHome = __basePy.substring(0, __basePy.lastIndexOf("/")).replace(/\//g, "\\");
      __basePy = __basePy.replace(/\//g, "\\");
      var __venvWin = __rootbs + "\\runtime\\agent\\venv";
      var __oldRoot = null;
      var __homeMatch = /^home\s*=\s*(.+)$/m.exec(__cfgtext);
      if (__homeMatch) {
        var __oldHome = __homeMatch[1].trim();
        var __mi = __oldHome.toLowerCase().indexOf("\\runtime\\python\\");
        if (__mi >= 0) { __oldRoot = __oldHome.substring(0, __mi); }
      }
      var __newCfg = __cfgtext.split(/\r?\n/).map(function(__line) {
        if (/^home\s*=/.test(__line)) { return "home = " + __basePyHome; }
        if (/^executable\s*=/.test(__line)) { return "executable = " + __basePy; }
        if (/^command\s*=/.test(__line)) { return "command = " + __basePy + " -m venv --without-pip " + __venvWin; }
        return __line;
      }).join("\r\n");
      __fsmod.writeFileSync(__hrun + "/agent/venv/pyvenv.cfg", __newCfg + "\r\n", "utf8");
      if (__oldRoot && __oldRoot.toLowerCase() !== __rootbs.toLowerCase()) {
        var __rebind = function(__dir, __nameOk, __from, __to) {
          try {
            var __files = __fsmod.readdirSync(__dir);
            for (var __j = 0; __j < __files.length; __j++) {
              if (!__nameOk(__files[__j])) { continue; }
              var __fp = __dir + "\\" + __files[__j];
              try {
                var __st = __fsmod.statSync(__fp);
                if (!__st.isFile() || __st.size > 8388608) { continue; }
                var __txt = __fsmod.readFileSync(__fp, "utf8");
                if (__txt.indexOf(__from) >= 0) {
                  __fsmod.writeFileSync(__fp, __txt.split(__from).join(__to), "utf8");
                }
              } catch (e3) {}
            }
          } catch (e3) {}
        };
        __rebind(__venvWin + "\\Scripts", function(__n) {
          return /\.(bat|ps1|py)$/i.test(__n) || __n.indexOf(".") < 0;
        }, __oldRoot, __rootbs);
        var __oldSer = __oldRoot.replace(/\\/g, "\\\\");
        var __newSer = __rootbs.replace(/\\/g, "\\\\");
        try {
          var __sp = __fsmod.readdirSync(__venvWin + "\\Lib\\site-packages");
          for (var __k = 0; __k < __sp.length; __k++) {
            if (/^__editable___hermes_agent_.*_finder\.py$/.test(__sp[__k])) {
              var __fpf = __venvWin + "\\Lib\\site-packages\\" + __sp[__k];
              try {
                var __tf = __fsmod.readFileSync(__fpf, "utf8");
                if (__tf.indexOf(__oldSer) >= 0) {
                  __fsmod.writeFileSync(__fpf, __tf.split(__oldSer).join(__newSer), "utf8");
                }
              } catch (e4) {}
            }
          }
        } catch (e4) {}
      }
      var __cfg2 = __fsmod.readFileSync(__hrun + "/agent/venv/pyvenv.cfg", "utf8");
      if (__cfg2.indexOf(__rootbs) < 0 && __cfg2.indexOf(__hroot) < 0) {
        throw new Error("venv repair did not take effect");
      }
    } catch (e) {
      __repairError = e;
    }
    if (__repairError) {
      try {
        var __eld = await import("electron");
        if (__eld && __eld.dialog && __eld.dialog.showErrorBox) {
          __eld.dialog.showErrorBox("Hermes Portable Environment Repair Failed", "Detected that the Hermes directory has been moved, but the bundled Python environment could not be repaired automatically.\n\nError: " + (__repairError.message || String(__repairError)) + "\n\nPlease rebuild, or restore the directory to its original location.");
        }
      } catch (e5) {}
      process.exit(1);
    }
  }
} catch (e) {}
'@
    if ($CommonJS) {
        # CommonJS 主进程没有顶层 await：用 require 替换动态 import
        $bootstrap = $bootstrap.Replace('await import("node:fs")', 'require("fs")')
        $bootstrap = $bootstrap.Replace('await import("electron")', 'require("electron")')
    }
    return $bootstrap
}

function Test-PortableBootstrapInjected {
    # 检查已打包的 app 是否携带便携引导
    # 新版（ESM）：引导内联在 app.asar.unpacked\dist\electron-main.mjs
    # 旧版（CJS）：引导内联在 app.asar 归档内的主入口，asar 明文存储文件内容
    param([string]$App)
    $esmMain = Join-Path $App 'resources\app.asar.unpacked\dist\electron-main.mjs'
    if (Test-Path -LiteralPath $esmMain) {
        return [System.IO.File]::ReadAllText($esmMain).Contains('// Hermit-Hermes 便携环境引导')
    }
    $asarFile = Join-Path $App 'resources\app.asar'
    if (-not (Test-Path -LiteralPath $asarFile)) { return $false }
    return [System.IO.File]::ReadAllText($asarFile).Contains('// Hermit-Hermes 便携环境引导')
}

function Inject-PortableEnvironment {
    # 在 Electron 主入口最顶部内联极简环境引导，从 exe 路径推导便携根目录并设置
    # Get-PortableEnvironment 提供的私有环境，直接启动 Hermes.exe 时依然保持完全隔离，
    # 不会回退到真实用户目录。
    # 新版（v2026.7.20+）：入口是 esbuild 打包的 dist\electron-main.mjs，被 electron-builder
    # 解包到 app.asar.unpacked（不在 asar 归档内），构建后直接内联。
    # 旧版（v2026.6.5 ~ v2026.7.7.2）：入口 electron\main.cjs 会被打包进 asar 归档内部，
    # 构建后无法修改，由 Build-Desktop 在打包前预注入，这里仅校验产物携带引导。
    param([string]$AppRoot)
    $dist = Join-Path $AppRoot 'resources\app.asar.unpacked\dist'
    $main = Join-Path $dist 'electron-main.mjs'
    if (-not (Test-Path -LiteralPath $main)) {
        # 旧版（CJS 时代）：入口在 asar 归档内部，打包前已预注入
        $asarFile = Join-Path $AppRoot 'resources\app.asar'
        if (-not (Test-Path -LiteralPath $asarFile)) { throw "Cannot inject portable environment: missing $asarFile" }
        if (-not (Test-PortableBootstrapInjected -App $AppRoot)) {
            throw 'Cannot inject portable environment: app.asar does not contain the portable environment bootstrap.'
        }
        Write-Ok 'Portable environment bootstrap is embedded in the Hermes.exe entry (CommonJS).' -Source 'inject'
        return
    }
    $bootstrapFile = Join-Path $dist 'hermit-env-bootstrap.mjs'
    # 必须按 UTF-8 读取：electron-main.mjs 含非 ASCII 字符（如 esbuild 注释里的 em dash），
    # Get-Content 默认按 ANSI（GBK）解码会乱码，写回时造成数据损坏
    $content = [System.IO.File]::ReadAllText($main, [System.Text.UTF8Encoding]::new($false))
    # 引导文件仍写入 app.asar.unpacked\dist，供完整性验证与排查使用
    $bootstrap = Get-PortableBootstrap
    [System.IO.File]::WriteAllText($bootstrapFile, $bootstrap, [System.Text.UTF8Encoding]::new($false))
    $importLine = 'import "./hermit-env-bootstrap.mjs";'
    $bootstrapMarker = '// Hermit-Hermes 便携环境引导'
    if ($content.Contains($importLine)) {
        # 旧式注入残留：把 import 替换为内联代码
        $content = $content.Replace($importLine, $bootstrap)
        [System.IO.File]::WriteAllText($main, $content, [System.Text.UTF8Encoding]::new($false))
        Write-BuildLog 'Inlined portable environment bootstrap into electron-main.mjs (replaced legacy import)' 'INFO' 'inject'
    }
    elseif (-not $content.Contains($bootstrapMarker)) {
        # 全新主入口：把引导代码内联到最顶部
        [System.IO.File]::WriteAllText($main, $bootstrap + "`n" + $content, [System.Text.UTF8Encoding]::new($false))
        Write-BuildLog 'Inlined portable environment bootstrap at the top of electron-main.mjs' 'INFO' 'inject'
    }
    else {
        Write-Info 'Portable environment bootstrap already inlined.' -Source 'inject'
        return
    }
    Write-Ok 'Portable environment bootstrap inlined into the Hermes.exe entry.' -Source 'inject'
}

function Build-Desktop {
    # 安装桌面端 node_modules 并运行 electron-builder 打包 Hermes Desktop
    param([string]$Source, [string]$Runtime)

    $environment = Get-PortableEnvironment -Runtime $Runtime -Data (Join-Path $script:HermesDir 'data') -NodeCache (Join-Path $script:BuildDir 'cache\npm')
    $npm = Join-Path $Runtime 'node\npm.cmd'
    # node-pty 在正常版本中自带 Windows 预编译产物，受限的 PATH
    # 刻意让意外的 node-gyp/Visual Studio 回退失败，
    # 而不是悄悄借用系统编译器
    Invoke-External -FilePath $npm -Arguments @('ci', '--no-audit', '--no-fund') -WorkingDirectory $Source -Environment $environment -Quiet -Activity 'Installing Desktop build dependencies' -LogSource 'npm-desktop'
    $desktop = Join-Path $Source 'apps\desktop'
    $desktopPkg = Get-Content -LiteralPath (Join-Path $desktop 'package.json') -Raw | ConvertFrom-Json
    if ($desktopPkg.main -and $desktopPkg.main -notlike 'dist/*') {
        # 旧版（CJS 时代）：入口 electron\main.cjs 会被 electron-builder 打包进
        # asar 归档内部，构建后无法修改，因此在打包前把引导内联进源码入口
        $mainCjs = Join-Path $desktop $desktopPkg.main
        if (-not (Test-Path -LiteralPath $mainCjs)) { throw "Desktop main entry is missing: $mainCjs" }
        $content = [System.IO.File]::ReadAllText($mainCjs, [System.Text.UTF8Encoding]::new($false))
        if (-not $content.Contains('// Hermit-Hermes 便携环境引导')) {
            $bootstrap = Get-PortableBootstrap -CommonJS
            [System.IO.File]::WriteAllText($mainCjs, $bootstrap + "`n" + $content, [System.Text.UTF8Encoding]::new($false))
            Write-BuildLog "Inlined portable environment bootstrap into $($desktopPkg.main) (pre-pack)" 'INFO' 'inject'
        }
    }
    Invoke-External -FilePath $npm -Arguments @('run', 'pack') -WorkingDirectory $desktop -Environment $environment -Quiet -Activity 'Packaging Hermes Desktop' -LogSource 'pack'
    $built = Join-Path $desktop 'release\win-unpacked'
    if (-not (Test-Path -LiteralPath (Join-Path $built 'Hermes.exe'))) { throw 'Desktop build did not produce Hermes.exe.' }
    return $built
}

function Test-ComponentCopy {
    # 判断给定目录是否为 runtime 组件的完整副本（被解引用的旧链接）：
    # 通过各组件独有的标志文件识别，避免误删真正的用户数据
    param([string]$Name, [string]$Path)
    switch ($Name) {
        'git' { return (Test-Path -LiteralPath (Join-Path $Path 'git-bash.exe')) -or (Test-Path -LiteralPath (Join-Path $Path 'cmd\git.exe')) }
        'node' { return Test-Path -LiteralPath (Join-Path $Path 'node.exe') }
        'bin' { return Test-Path -LiteralPath (Join-Path $Path 'uv.exe') }
        'hermes-agent' { return Test-Path -LiteralPath (Join-Path $Path 'venv\Scripts\python.exe') }
        default { return $false }
    }
}

function Ensure-CompatibilityLinks {
    # 重建 data\ 下指向 runtime 组件的目录联接（junction）
    $data = Join-Path $script:HermesDir 'data'
    Ensure-Directory $data | Out-Null
    $targets = @{
        'hermes-agent' = (Join-Path $script:HermesDir 'runtime\agent')
        'node' = (Join-Path $script:HermesDir 'runtime\node')
        'bin' = (Join-Path $script:HermesDir 'runtime\uv\bin')
        'git' = (Join-Path $script:HermesDir 'runtime\git')
    }
    foreach ($name in $targets.Keys) {
        $link = Join-Path $data $name
        $targetPath = $targets[$name]
        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if (-not $item.LinkType) {
                # 目录迁移时链接可能被解引用成组件副本：内容与 runtime 组件一致时自动重建，
                # 否则（可能是用户数据）保持拦截，避免误删
                if ((Test-Path -LiteralPath $targetPath) -and (Test-ComponentCopy -Name $name -Path $link)) {
                    Write-BuildLog "Removing dereferenced component copy: $link" 'WARN' 'fs'
                    Remove-Item -LiteralPath $link -Recurse -Force
                    New-Item -ItemType Junction -Path $link -Target $targetPath | Out-Null
                    Write-BuildLog "Rebuilt link: $link -> $targetPath" 'INFO' 'fs'
                }
                else {
                    throw "Compatibility path already exists and is not an internal link: $link"
                }
                continue
            }
            # 布局变化（去掉 current 层）后旧联接目标可能失效：目标不一致时重建
            $currentTarget = if ($item.Target -is [array]) { ($item.Target -join '') } else { [string]$item.Target }
            if (-not [string]::Equals($currentTarget, $targetPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $link -Force
                New-Item -ItemType Junction -Path $link -Target $targetPath | Out-Null
                Write-BuildLog "Rebuilt link: $link -> $targetPath" 'INFO' 'fs'
            }
            continue
        }
        New-Item -ItemType Junction -Path $link -Target $targetPath | Out-Null
        Write-BuildLog "Created link: $link -> $targetPath" 'INFO' 'fs'
    }
}

function Repair-RelocatedVenv {
    param([string]$OldRuntime, [string]$CurrentRuntime)

    # 标准 venv 记录了其基础 CPython 的绝对路径，发布时候选运行时
    # 会从候选目录改名为 runtime，因此需在 Desktop 启动 venv 前更新该路径前缀
    $config = Join-Path $CurrentRuntime 'agent\venv\pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $config)) {
        throw "Portable venv configuration is missing: $config"
    }
    $text = [System.IO.File]::ReadAllText($config)
    if ($text.Contains($OldRuntime)) {
        $text = $text.Replace($OldRuntime, $CurrentRuntime)
        [System.IO.File]::WriteAllText($config, $text, [System.Text.UTF8Encoding]::new($false))
    }
    if ([System.IO.File]::ReadAllText($config).Contains($OldRuntime)) {
        throw "Portable venv still references its staging path: $config"
    }
}

function Repair-PortableRelocation {
    # Python venv 元数据与 setuptools 可编辑安装保留绝对路径，
    # 将这些生成文件重定位到脚本当前目录，
    # 使整个 Hermes 目录可移动而无需重建
    $runtime = Join-Path $script:HermesDir 'runtime'
    $agent = Join-Path $runtime 'agent'
    $venv = Join-Path $agent 'venv'
    $config = Join-Path $venv 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $config)) { return }

    $basePython = Get-PortableBasePython -Runtime $runtime
    $basePythonHome = Split-Path -Parent $basePython
    $configText = [System.IO.File]::ReadAllText($config)
    $oldRoot = $null
    $oldHome = $configText -split "`r?`n" | Where-Object { $_ -match '^home\s*=\s*' } | Select-Object -First 1
    if ($oldHome) {
        $oldHome = ($oldHome -replace '^home\s*=\s*', '').Trim()
        $runtimeMarker = '\runtime\python\'
        $markerIndex = $oldHome.IndexOf($runtimeMarker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) { $oldRoot = $oldHome.Substring(0, $markerIndex) }
    }

    $newLines = foreach ($line in ($configText -split "`r?`n")) {
        if ($line -match '^home\s*=') { "home = $basePythonHome" }
        elseif ($line -match '^executable\s*=') { "executable = $basePython" }
        elseif ($line -match '^command\s*=') { "command = $basePython -m venv --without-pip $venv" }
        else { $line }
    }
    [System.IO.File]::WriteAllText($config, (($newLines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))

    if ($oldRoot -and -not [string]::Equals($oldRoot, $script:HermesDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Get-ChildItem -LiteralPath (Join-Path $venv 'Scripts') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.bat', '.ps1', '.py', '') } |
            ForEach-Object {
                $text = [System.IO.File]::ReadAllText($_.FullName)
                if ($text.Contains($oldRoot)) {
                    [System.IO.File]::WriteAllText($_.FullName, $text.Replace($oldRoot, $script:HermesDir), [System.Text.UTF8Encoding]::new($false))
                }
            }

        $oldSerializedRoot = $oldRoot.Replace('\', '\\')
        $newSerializedRoot = $script:HermesDir.Replace('\', '\\')
        Get-ChildItem -LiteralPath (Join-Path $venv 'Lib\site-packages') -File -Filter '__editable___hermes_agent_*_finder.py' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $text = [System.IO.File]::ReadAllText($_.FullName)
                if ($text.Contains($oldSerializedRoot)) {
                    [System.IO.File]::WriteAllText($_.FullName, $text.Replace($oldSerializedRoot, $newSerializedRoot), [System.Text.UTF8Encoding]::new($false))
                }
            }
        Write-BuildLog "Relocation: rebased venv metadata from $oldRoot to $($script:HermesDir)" 'INFO' 'repair'
    }

    $environment = Get-PortableEnvironment -Runtime $runtime -Data (Join-Path $script:HermesDir 'data') -NodeCache (Join-Path $script:BuildDir 'cache\npm')
    Invoke-External -FilePath (Join-Path $venv 'Scripts\python.exe') -Arguments @('-c', 'import hermes_cli, dotenv, openai, rich, prompt_toolkit') -WorkingDirectory $agent -Environment $environment -Quiet -LogSource 'verify'
    Write-Ok 'Portable paths are valid for the current Hermes directory.'
}

function Get-PortableBasePython {
    # 定位创建 venv 所用的 uv 托管 CPython
    param([string]$Runtime)

    $candidate = Get-ChildItem -LiteralPath (Join-Path $Runtime 'python') -Recurse -File -Filter 'python.exe' |
        Where-Object { $_.Directory.Name -match '^cpython-.*-windows-x86_64-none$' } |
        Select-Object -First 1
    if (-not $candidate) { throw "Bundled CPython is missing below: $(Join-Path $Runtime 'python')" }
    return $candidate.FullName
}

function New-StandardPortableVenv {
    param(
        [string]$Runtime,
        [string]$Agent,
        [hashtable]$Environment,
        [switch]$SkipSync
    )

    $venv = Join-Path $Agent 'venv'
    if (Test-Path -LiteralPath $venv) {
        throw "Refusing to overwrite an existing venv: $venv"
    }

    $basePython = Get-PortableBasePython -Runtime $Runtime
    # uv 托管的 CPython 刻意不带可用的 ensurepip 包，
    # uv 自行安装锁定的依赖，因此创建不带 pip 的标准 venv，
    # 而不是退化为 uv 跳板 venv
    Invoke-External -FilePath $basePython -Arguments @('-m', 'venv', '--without-pip', $venv) -WorkingDirectory $Agent -Environment $Environment -Quiet -Activity 'Creating the Agent Python environment' -LogSource 'venv'
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) { throw "Standard venv creation did not produce Python: $venvPython" }
    if (-not $SkipSync) {
        Sync-StandardPortableVenv -Runtime $Runtime -Agent $Agent -Environment $Environment
    }
}

function Sync-StandardPortableVenv {
    param([string]$Runtime, [string]$Agent, [hashtable]$Environment)

    $venv = Join-Path $Agent 'venv'
    $venvPython = Join-Path $venv 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) { throw "Standard venv Python is missing: $venvPython" }
    $Environment.VIRTUAL_ENV = $venv
    $uv = Join-Path $Runtime 'uv\bin\uv.exe'
    # Hermes 刻意拒绝以 wheel/sdist 方式构建自身，受支持的安装方式是可编辑安装，
    # --active 保持该可编辑链接位于上述标准 venv 内
    Invoke-External -FilePath $uv -Arguments @('sync', '--active', '--locked', '--extra', 'all') -WorkingDirectory $Agent -Environment $Environment -Quiet -Activity 'Installing Agent Python dependencies' -LogSource 'uv'

    Invoke-External -FilePath $venvPython -Arguments @('-c', 'import hermes_cli, dotenv, openai, rich, prompt_toolkit') -WorkingDirectory $Agent -Environment $Environment -Quiet -Activity 'Verifying Agent Python modules' -LogSource 'verify'
}

function Test-PortableInstall {
    # 发布前验证安装完整性：核心文件齐全 + Python/Node/ripgrep/FFmpeg 可运行
    param(
        [string]$Runtime = (Join-Path $script:HermesDir 'runtime'),
        [string]$App = (Join-Path $script:HermesDir 'app'),
        [switch]$RequireBootstrap
    )

    $required = @(
        (Join-Path $App 'Hermes.exe'),
        (Join-Path $runtime 'agent\venv\Scripts\python.exe'),
        (Join-Path $runtime 'node\node.exe'),
        (Join-Path $runtime 'git\bin\bash.exe'),
        (Join-Path $runtime 'uv\bin\uv.exe'),
        (Join-Path $script:HermesDir 'tools\ripgrep\rg.exe'),
        (Join-Path $script:HermesDir 'tools\ffmpeg\ffmpeg.exe'),
        (Join-Path $script:HermesDir 'tools\ffmpeg\ffprobe.exe'),
        (Join-Path $script:HermesDir 'tools\ffmpeg\ffplay.exe')
    )
    if ($RequireBootstrap) {
        # 新构建候选必须携带注入的环境引导；已发布的旧版本（注入功能前构建）
        # 没有该文件仍可正常运行，验证时宽容跳过。
        # 新版引导文件在 app.asar.unpacked\dist；旧版内联在 app.asar 归档内，
        # 没有独立引导文件，改为校验归档内的引导标记
        if (-not (Test-PortableBootstrapInjected -App $App)) {
            $required += (Join-Path $App 'resources\app.asar.unpacked\dist\hermit-env-bootstrap.mjs')
        }
    }
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing) { throw "Portable install is incomplete:`n$($missing -join "`n")" }
    $environment = Get-PortableEnvironment -Runtime $runtime -Data (Join-Path $script:HermesDir 'data') -NodeCache (Join-Path $script:BuildDir 'cache\npm')
    Invoke-External -FilePath (Join-Path $runtime 'agent\venv\Scripts\python.exe') -Arguments @('-c', 'import hermes_cli, dotenv, openai, rich, prompt_toolkit') -WorkingDirectory (Join-Path $runtime 'agent') -Environment $environment -Quiet -Activity 'Verifying the Agent runtime' -LogSource 'verify'
    $basePython = Get-PortableBasePython -Runtime $runtime
    $environment.PYTHONPATH = (Join-Path $runtime 'agent\venv\Lib\site-packages')
    Invoke-External -FilePath $basePython -Arguments @('-c', 'import hermes_cli, dotenv, openai, rich, prompt_toolkit') -WorkingDirectory (Join-Path $runtime 'agent') -Environment $environment -Quiet -Activity 'Verifying bundled Python' -LogSource 'verify'
    Invoke-External -FilePath (Join-Path $script:HermesDir 'tools\ripgrep\rg.exe') -Arguments @('--version') -Environment $environment -Quiet -Activity 'Verifying ripgrep' -LogSource 'verify'
    Invoke-External -FilePath (Join-Path $script:HermesDir 'tools\ffmpeg\ffmpeg.exe') -Arguments @('-version') -Environment $environment -Quiet -Activity 'Verifying FFmpeg' -LogSource 'verify'
    Write-Ok 'Portable runtime files and core imports are valid.'
}

function Publish-Candidate {
    # 发布候选版本：旧 app 换名 __old 兜底、候选换名 app、修复路径、验证、删 __old 并记录版本信息
    param([string]$AppNext, [string]$RuntimeNext, [string]$ReleaseTag, [string]$Commit)

    $appLive = Join-Path $script:HermesDir 'app'
    $appOld = Join-Path $script:HermesDir 'app.__old'
    $runtimeLive = Join-Path $script:HermesDir 'runtime'
    $runtimeOld = Join-Path $script:HermesDir 'runtime.__old'
    # 旧版 __old 残留必须清干净才能发布（换名目标不能已存在）；
    # 清理失败通常是旧版本文件仍被占用（Hermes 或残留 agent 进程），给出明确提示
    foreach ($oldDir in @($appOld, $runtimeOld)) {
        try {
            Remove-PortableTree $oldDir
        }
        catch {
            throw "A previous version is still in use and could not be cleaned: $oldDir. Close Hermes and any leftover Hermes python processes, then re-run the script."
        }
    }

    $movedApp = $false
    $movedRuntime = $false
    try {
        # 原子发布：先把旧版本换名到 __old 兜底（失败可还原），
        # 再把候选换名成 app——同卷换名秒级完成，无复制开销
        if (Test-Path -LiteralPath $appLive) {
            Move-Item -LiteralPath $appLive -Destination $appOld
            $movedApp = $true
            Write-BuildLog "Moved: $appLive -> $appOld" 'INFO' 'publish'
        }
        if (Test-Path -LiteralPath $runtimeLive) {
            Move-Item -LiteralPath $runtimeLive -Destination $runtimeOld
            $movedRuntime = $true
            Write-BuildLog "Moved: $runtimeLive -> $runtimeOld" 'INFO' 'publish'
        }
        Move-Item -LiteralPath $AppNext -Destination $appLive
        Write-BuildLog "Moved: $AppNext -> $appLive" 'INFO' 'publish'
        Move-Item -LiteralPath $RuntimeNext -Destination $runtimeLive
        Write-BuildLog "Moved: $RuntimeNext -> $runtimeLive" 'INFO' 'publish'
        # 候选 -> app 改名后，venv 里记录的绝对路径（含候选路径）已失效，
        # 需要把 venv 元数据重定位到 app，并同步可编辑安装链接
        Repair-RelocatedVenv -OldRuntime $RuntimeNext -CurrentRuntime $runtimeLive
        $publishedEnvironment = Get-PortableEnvironment -Runtime $runtimeLive -Data (Join-Path $script:HermesDir 'data') -NodeCache (Join-Path $script:BuildDir 'cache\npm')
        Sync-StandardPortableVenv -Runtime $runtimeLive -Agent (Join-Path $runtimeLive 'agent') -Environment $publishedEnvironment
    }
    catch {
        # 换名中途失败时还原：把 __old 换回 app，保证任何时刻都有可用版本
        if (-not (Test-Path -LiteralPath $appLive) -and $movedApp -and (Test-Path -LiteralPath $appOld)) { Move-Item -LiteralPath $appOld -Destination $appLive }
        if (-not (Test-Path -LiteralPath $runtimeLive) -and $movedRuntime -and (Test-Path -LiteralPath $runtimeOld)) { Move-Item -LiteralPath $runtimeOld -Destination $runtimeLive }
        throw
    }

    Ensure-CompatibilityLinks
    # 发布后整理 Hermes 根目录：只清理本构建器产生过的旧版残留
    # （旧根目录 cache、标记文件、旧启动器、__old 兜底目录），
    # 其它未知内容一律保留——绝不删除用户自行放入的文件；
    # data 与 backups 属于用户数据，绝不触碰
    $knownResidue = @('cache', 'Hermit-Hermes.txt', 'Start-Hermes.cmd', 'app.__old', 'runtime.__old')
    foreach ($item in @(Get-ChildItem -LiteralPath $script:HermesDir -Force)) {
        if ($item.Name -in $knownResidue) {
            if ($item.PSIsContainer) { Remove-PortableTree $item.FullName }
            else { Remove-Item -LiteralPath $item.FullName -Force }
            Write-BuildLog "Removed known build residue: $($item.FullName)" 'INFO' 'publish'
        }
    }
    $manifest = [ordered]@{
        schema = 1
        releaseTag = $ReleaseTag
        commit = $Commit
        builtAt = (Get-Date).ToUniversalTime().ToString('o')
        source = $script:SourceRepo
    } | ConvertTo-Json
    Ensure-Directory (Join-Path $script:HermesDir 'manifests') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $script:HermesDir 'manifests\installed.json'), $manifest + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-BuildLog "Manifest written: manifests\installed.json ($ReleaseTag @ $Commit)" 'INFO' 'publish'
}

function Update-SelfCopy {
    # 首次安装完全成功后，若脚本仍位于构建根目录（尚未迁入 Hermes），
    # 把自身复制到 Hermes\ 目录并删除根目录原件；下次起从 Hermes 内副本运行，
    # 副本通过 manifests\installed.json 自动把构建根目录推导为 Hermes 目录的上一级
    # 构建前已有版本记录（更新/验证场景）不迁移脚本位置；只有首次安装才迁入 Hermes
    if ($script:HadInstall) { return }
    $scriptDir = Split-Path -Parent $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($scriptDir)) { $scriptDir = (Get-Location).Path }
    $scriptDir = [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\\')
    if (-not [string]::Equals($scriptDir, $script:Root, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    $selfName = Split-Path -Leaf $PSCommandPath
    $target = Join-Path $script:HermesDir $selfName
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force
        Write-Ok "Installed the build script into Hermes: $target" -Source 'self'
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction Stop
        Write-Info "Removed the launcher: $PSCommandPath. Next time run: $target" -Source 'self'
    }
    catch {
        Write-WarnPortable "Self relocation failed (non-fatal): $($_.Exception.Message)" -Source 'self'
    }
}

function Confirm-BuildStart {
    # 任何真实构建工作开始前的友好确认门：只想看看脚本的人可以直接离开，
    # 而不会触发漫长的下载与构建
    # 输入被重定向或传入 -SkipConfirm 时自动跳过
    param(
        [string]$Action = 'Update',
        [string]$Version = ''
    )
    $rule = '=' * 50
    Write-Host ''
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host '  Hermes Desktop Builder  ' -ForegroundColor White -BackgroundColor DarkCyan
    Write-Host $rule -ForegroundColor DarkCyan
    Write-Host ("  Action    : $Action") -ForegroundColor White
    if ($Version) { Write-Host ("  Version   : $Version") -ForegroundColor White }
    Write-Host '  Duration  : ~5 min with caches, 10-20 min on first build (depends on network)' -ForegroundColor Gray
    Write-Host '  Safety    : user data under data\ is never touched' -ForegroundColor Gray
    Write-Host $rule -ForegroundColor DarkCyan
    if (-not [Console]::IsInputRedirected) {
        Read-Host 'Press Enter to start (Ctrl+C to cancel)'
    }
    Write-Host ''
}

function Assert-HermesNotRunning {
    # 更新会原子替换 app\runtime，Hermes 正在运行时文件被占用会导致发布失败，
    # 因此在任何构建工作开始前检测并阻止。
    # 只检测 Hermes 目录内的进程（app\Hermes.exe 与 runtime 下的 python），
    # 不检测系统其他位置的同名程序，避免误伤无关进程
    $hermesPrefix = $script:HermesDir + [System.IO.Path]::DirectorySeparatorChar
    $hermesProc = Get-Process -Name 'Hermes' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($hermesPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($hermesProc) {
        throw "Hermes Desktop is currently running from $($hermesProc.Path). Please close it and re-run the script - the update swaps its files and would fail while it is open."
    }
    # Hermes 的 Agent 后台进程（runtime 下的 python.exe）会持有旧 runtime 文件句柄，
    # 导致发布后清理 __old 失败；同样只检测 Hermes 目录内的 python
    $pythonPrefix = (Join-Path $script:HermesDir 'runtime') + [System.IO.Path]::DirectorySeparatorChar
    $pythonProc = Get-Process -Name 'python' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($pythonPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($pythonProc) {
        throw "A Hermes agent process is still running ($($pythonProc.Path)). Please close Hermes and any leftover Hermes python processes, then re-run the script."
    }
    Write-Ok 'Preflight: Hermes is not running.' -Source 'preflight'
}

function Invoke-Preflight {
    # 构建前的只读环境预检（网络/磁盘），让明显问题几秒内暴露

    # git 实际连接的是 github.com（而非 api.github.com）。
    # 只做 TCP 握手不够：真实下载还会 302 到 release-assets.githubusercontent.com CDN，
    # 因此同时探测 HTTPS 层与下载 CDN，避免预检通过却在下载阶段失败
    $gitProbe = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $gitProbe.ConnectAsync('github.com', 443)
        $gitReachable = $connectTask.Wait(3000) -and $gitProbe.Connected
    }
    catch {
        $gitReachable = $false
    }
    finally {
        $gitProbe.Dispose()
    }
    $gitHttps = $false
    if ($gitReachable) {
        try {
            $probe = [System.Net.HttpWebRequest]::Create('https://github.com/')
            $probe.Method = 'HEAD'
            $probe.Timeout = 6000
            $probe.UserAgent = 'Hermes-Builder'
            $probe.AllowAutoRedirect = $true
            $probe.GetResponse().Dispose()
            $gitHttps = $true
        }
        catch {
            $gitHttps = $false
        }
    }
    $cdnProbe = New-Object System.Net.Sockets.TcpClient
    try {
        $cdnTask = $cdnProbe.ConnectAsync('release-assets.githubusercontent.com', 443)
        $cdnReachable = $cdnTask.Wait(3000) -and $cdnProbe.Connected
    }
    catch {
        $cdnReachable = $false
    }
    finally {
        $cdnProbe.Dispose()
    }

    if ($gitHttps) {
        Write-Ok 'Preflight: github.com reachable (git endpoint).' -Source 'preflight'
    }
    elseif ($env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:ALL_PROXY) {
        Write-WarnPortable 'Preflight: github.com direct probe failed, but a proxy env is set - continuing.' -Source 'preflight'
    }
    else {
        throw 'Preflight: cannot reach github.com over HTTPS - check your network or proxy before building.'
    }

    if ($cdnReachable) {
        Write-Ok 'Preflight: github.com download CDN reachable.' -Source 'preflight'
    }
    elseif ($env:HTTPS_PROXY -or $env:HTTP_PROXY -or $env:ALL_PROXY) {
        Write-WarnPortable 'Preflight: download CDN direct probe failed, but a proxy env is set - continuing.' -Source 'preflight'
    }
    else {
        throw 'Preflight: cannot reach the GitHub download CDN (release-assets.githubusercontent.com) - check your network or proxy before building.'
    }

    # 版本查询/下载清单仍依赖 api.github.com：失败才拦截，通过不单独输出
    try {
        $null = Invoke-RestMethod -Uri 'https://api.github.com/rate_limit' -Headers $script:GitHubHeaders -TimeoutSec 8
    }
    catch {
        throw "Preflight: cannot reach api.github.com - check your network or proxy before building. $($_.Exception.Message)"
    }

    $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($script:Root))
    $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($drive.AvailableFreeSpace -lt 6GB) {
        throw "Preflight: only $freeGb GB free disk space - a full build needs ~6-12 GB. Free up space, then re-run the script."
    }
    else {
        Write-Ok "Preflight: disk free $freeGb GB." -Source 'preflight'
    }
}

function Build-AndPublish {
    # 主流程：预检、工具、源码、运行时、桌面端、发布验证 6 阶段
    Assert-PortableRoot
    Ensure-Directory $script:Root | Out-Null
    foreach ($directory in @('app', 'runtime', 'data', 'manifests')) {
        Ensure-Directory (Join-Path $script:HermesDir $directory) | Out-Null
    }
    foreach ($directory in @('cache\downloads', 'cache\sources', 'cache\npm', 'cache\uv', 'cache\tmp')) {
        Ensure-Directory (Join-Path $script:BuildDir $directory) | Out-Null
    }
    Start-BuildLog
    Write-Stage -Name 'Preparing the private build environment' -Step '1/6'
    # 预检全只读：先暴露 Hermes 运行/网络/磁盘/版本问题，避免长构建白跑；
    # 随后修复目录迁移导致的 venv 路径偏移（移动过目录才真正动文件）
    Assert-HermesNotRunning
    Invoke-Preflight
    Repair-PortableRelocation

    $releaseTag = if ($Tag) { $Tag.Trim() } else { Get-LatestStableTag }
    $installedPath = Join-Path $script:HermesDir 'manifests\installed.json'
    # 记录构建开始时的安装状态：发布阶段会改写 installed.json，必须在改写前取值
    $script:HadInstall = Test-Path -LiteralPath $installedPath
    # 已是最新版本时不重建，只做一次安装完整性验证后结束（不弹确认、零下载）
    if ((Test-Path -LiteralPath $installedPath) -and -not $Tag) {
        $installed = Get-Content -LiteralPath $installedPath -Raw | ConvertFrom-Json
        if ($installed.releaseTag -eq $releaseTag) {
            Write-Info "Preflight: already on the latest release ($releaseTag) - the existing install will be verified." -Source 'preflight'
            Write-Stage -Name 'Verifying the current Hermes installation' -Step '6/6'
            Ensure-CompatibilityLinks
            Test-PortableInstall
            Write-Ok "Already built from the latest stable release: $releaseTag"
            Update-SelfCopy
            return
        }
        Write-Info "Preflight: installed $($installed.releaseTag), latest is $releaseTag - an update will be built." -Source 'preflight'
    }

    if (-not $SkipConfirm) {
        # 安装/更新一体：有安装记录=更新，无记录=全新安装，指定 Tag=构建指定版本
        $confirmAction = if ($Tag) { 'Build specified version' }
            elseif (Test-Path -LiteralPath $installedPath) { 'Update' }
            else { 'Install' }
        Confirm-BuildStart -Action $confirmAction -Version $releaseTag
    }

    # 确认后才准备引导工具：下载 PortableGit / uv 引导包属于实质工作
    # （约 75 MB），必须等用户确认后再进行，且只在实际需要构建时下载
    $git = Ensure-BootstrapGit
    $uv = Ensure-BootstrapUv

    Write-Stage -Name "Fetching official Hermes release $releaseTag" -Step '2/6'
    $worktree = Get-ReleaseWorktree -GitExe $git -ReleaseTag $releaseTag
    $appCandidate = Join-Path $script:BuildDir 'app-candidate'
    $runtimeCandidate = Join-Path $script:BuildDir 'runtime-candidate'
    Remove-PortableTree $appCandidate
    Remove-PortableTree $runtimeCandidate
    Ensure-Directory $appCandidate | Out-Null
    Ensure-Directory $runtimeCandidate | Out-Null

    $published = $false
    try {
        Write-Stage -Name 'Installing private tools' -Step '3/6'
        Install-PrivateTools
        Write-Stage -Name 'Installing the Hermes Agent runtime' -Step '4/6'
        Install-AgentRuntime -Source $worktree.Path -Runtime $runtimeCandidate -BootstrapUv $uv -BootstrapGit $git
        Write-Stage -Name 'Building Hermes Desktop' -Step '5/6'
        $builtDesktop = Build-Desktop -Source $worktree.Path -Runtime $runtimeCandidate
        Copy-DirectoryContents $builtDesktop $appCandidate
        Inject-PortableEnvironment -AppRoot $appCandidate
        if (-not (Test-Path -LiteralPath (Join-Path $appCandidate 'Hermes.exe'))) { throw 'Candidate Desktop is incomplete.' }
        Write-Stage -Name 'Validating and publishing the build' -Step '6/6'
        Test-PortableInstall -Runtime $runtimeCandidate -App $appCandidate -RequireBootstrap
        Publish-Candidate -AppNext $appCandidate -RuntimeNext $runtimeCandidate -ReleaseTag $worktree.Tag -Commit $worktree.Commit
        $published = $true
        # 发布后的 app 是新构建产物，必须携带注入引导
        Test-PortableInstall -RequireBootstrap
        # 发布已完全验证：删除 __old 兜底目录，不留旧版本；
        # 若旧版本文件仍被占用（如残留 agent python 进程），降级为警告，下次构建再重试清理
        foreach ($oldDir in @('app.__old', 'runtime.__old')) {
            try {
                Remove-PortableTree (Join-Path $script:HermesDir $oldDir)
            }
            catch {
                Write-WarnPortable "Old $oldDir cleanup skipped (files in use); will be retried on the next build." -Source 'publish'
            }
        }
        Write-Ok "Built Hermes $($worktree.Tag). Launch it with: $(Join-Path $script:HermesDir 'app\Hermes.exe')"
    }
    catch {
        $state = if ($published) { 'Build validation failed after publishing.' } else { 'Build failed. The active Hermes version was not replaced.' }
        Write-WarnPortable "$state $($_.Exception.Message)"
        throw
    }
    finally {
        if (-not $KeepBuild) {
            # 删除源码工作树（含 npm node_modules）可能较慢，
            # 与单项清理一致：运行中单行状态刷新，完成后输出带用时的完成行，
            # 清理失败绝不掩盖构建结果
            Write-BuildLog 'Cleaning up the temporary build workspace...' 'INFO' 'cleanup'
            try {
                Update-TaskStatus 'Cleaning up the temporary build workspace...'
                Remove-PortableTree (Join-Path $script:BuildDir 'source')
                Remove-PortableTree (Join-Path $script:BuildDir 'node-extract')
                Remove-PortableTree (Join-Path $script:BuildDir 'rg-extract')
                Remove-PortableTree (Join-Path $script:BuildDir 'ffmpeg-extract')
                Update-TaskStatus 'Cleaned up the temporary build workspace' -Complete -Ok
            }
            catch {
                Write-WarnPortable "Build workspace cleanup failed (non-fatal): $($_.Exception.Message)" -Source 'cleanup'
            }
        }
    }
    # 只有构建（或验证）完全成功才会执行到这里：把脚本迁入 Hermes 目录，
    # 删除根目录原件，下次起从 Hermes 内副本运行
    Update-SelfCopy
    Show-SuccessCard -Version $releaseTag -HermesPath (Join-Path $script:HermesDir 'app\Hermes.exe')
}

# 启动品牌卡：每次运行最先展示（所有模式）
Show-StartCard

# 强制脚本自更新检查：有新版本必须先更新，检查失败也阻止进入正式流程
$script:SelfPath = $MyInvocation.MyCommand.Path
if (Invoke-ScriptUpdateCheck) {
    return
}
try {
    if ($Backup) {
        Backup-PersonalData
    }
    elseif ($script:TagSpecified -and -not $Tag) {
        Show-AvailableVersions -All:$false
    }
    elseif ($Tag -ieq 'listall') {
        Show-AvailableVersions -All:$true
    }
    else {
        if ($Tag) {
            # 先做本地格式校验，再向上游确认版本存在，避免拼写错误/不存在的版本白跑构建
            if ($Tag -notmatch '^v\d+\.\d+\.\d+(?:[-.][0-9A-Za-z.-]+)?$') {
                Write-Host "Invalid -Tag value: $Tag" -ForegroundColor Yellow
                Write-Host 'Use a valid version (e.g. -Tag v2026.8.3), -Tag listall to list versions, or -Tag to show the latest ones.' -ForegroundColor Gray
                return
            }
            $tagExists = Test-HermesTagExists -Tag $Tag
            if ($tagExists -eq $false) {
                Write-Host "Version $Tag does not exist on the upstream repository." -ForegroundColor Yellow
                Write-Host 'Use -Tag listall to see all available versions.' -ForegroundColor Gray
                return
            }
            if (-not (Test-DesktopSupported $Tag)) {
                Write-Host "Version $Tag cannot be built: Hermes Desktop was only introduced upstream in v2026.6.5, so earlier releases cannot produce Hermes.exe." -ForegroundColor Yellow
                Write-Host 'Use -Tag listall to see versions that can be built.' -ForegroundColor Gray
                return
            }
        }
        Build-AndPublish
    }
}
catch {
    $failure = $_.Exception.Message
    Write-BuildLog "Build failed in stage '$($script:CurrentStage)': $failure" 'ERROR' 'main'
    Show-FailureCard -Failure $failure
}
finally {
    Stop-BuildLog
    # 退出前清掉单行刷新的残留（中断/结束时状态行会停在屏幕上）
    Clear-TaskStatusLine
}
