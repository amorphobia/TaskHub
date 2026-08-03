#requires -version 5.1
<#
    UserTaskManager - a least-privilege WPF front end for Task Scheduler 2.0.
    It deliberately uses the caller's token and never requests elevation.
#>

[CmdletBinding()]
param(
    [switch]$SmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Restart-InStaIfNeeded {
    if ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw '当前线程不是 STA，并且无法确定脚本路径。请运行 build.ps1 后使用生成的 UserTaskManager.cmd 启动。'
    }

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        throw '找不到 Windows PowerShell 5.1。'
    }

    $escapedPath = $PSCommandPath.Replace('"', '\"')
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershellExe
    $startInfo.Arguments = '-NoProfile -STA -File "{0}"' -f $escapedPath
    $startInfo.UseShellExecute = $false
    [void][Diagnostics.Process]::Start($startInfo)
    return $true
}

if (Restart-InStaIfNeeded) {
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

$script:AppName = 'UserTaskManager'
$script:TaskService = $null
$script:MainWindow = $null
$script:IsBusy = $false
$script:FolderPaths = New-Object 'System.Collections.Generic.List[string]'
$script:CurrentFolderPath = '\'
$script:CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:CurrentSid = $script:CurrentIdentity.User.Value
$script:CurrentUserName = $script:CurrentIdentity.Name
$script:LogDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'UserTaskManager'
$script:LogPath = Join-Path $script:LogDirectory 'UserTaskManager.log'

# Task Scheduler constants.
$script:TASK_CREATE = 2
$script:TASK_UPDATE = 4
$script:TASK_ENUM_HIDDEN = 1
$script:TASK_LOGON_INTERACTIVE_TOKEN = 3
$script:TASK_RUNLEVEL_LUA = 0
$script:TASK_TRIGGER_TIME = 1
$script:TASK_TRIGGER_DAILY = 2
$script:TASK_TRIGGER_LOGON = 9
$script:TASK_ACTION_EXEC = 0

# These helpers are embedded so the project does not depend on standalone
# wrapper.ps1 or run.vbs files. Background tasks receive private copies under
# %LOCALAPPDATA%\UserTaskManager\Tasks\<full-task-path-sha256>\.
$script:BackgroundWrapperContent = @'
#requires -version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'config.json'
$logDirectory = Join-Path $PSScriptRoot 'logs'
$wrapperErrorPath = Join-Path $logDirectory 'wrapper-error.log'
$exitCode = 1

$streamPumpSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace UserTaskManager
{
    public static class BackgroundProcessRunner
    {
        public static int Run(
            string executable,
            string arguments,
            string workingDirectory,
            string stdoutPath,
            string stderrPath)
        {
            using (var stdoutFile = new FileStream(
                stdoutPath, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var stderrFile = new FileStream(
                stderrPath, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var stdout = new StreamWriter(stdoutFile, new UTF8Encoding(false)))
            using (var stderr = new StreamWriter(stderrFile, new UTF8Encoding(false)))
            using (var process = new Process())
            {
                stdout.AutoFlush = true;
                stderr.AutoFlush = true;

                process.StartInfo = new ProcessStartInfo
                {
                    FileName = executable,
                    Arguments = arguments ?? String.Empty,
                    WorkingDirectory = workingDirectory ?? String.Empty,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                object stdoutLock = new object();
                object stderrLock = new object();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        lock (stdoutLock) { stdout.WriteLine(e.Data); }
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        lock (stderrLock) { stderr.WriteLine(e.Data); }
                    }
                };

                if (!process.Start())
                    throw new InvalidOperationException("Failed to start executable: " + executable);
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                // A second wait ensures asynchronous output event handlers finish.
                process.WaitForExit();
                return process.ExitCode;
            }
        }
    }
}
"@
try {
    Add-Type -TypeDefinition $streamPumpSource -Language CSharp
    if (-not [IO.File]::Exists($configPath)) {
        throw ('Background configuration does not exist: {0}' -f $configPath)
    }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $config.PSObject.Properties['LogDirectory'] -and
        -not [string]::IsNullOrWhiteSpace([string]$config.LogDirectory)) {
        $logDirectory = [IO.Path]::GetFullPath([string]$config.LogDirectory)
        $wrapperErrorPath = Join-Path $logDirectory 'wrapper-error.log'
    }
    if (-not [IO.Directory]::Exists($logDirectory)) {
        [void][IO.Directory]::CreateDirectory($logDirectory)
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.Executable)) {
        throw 'Executable is empty in config.json.'
    }

    # The executable and raw Windows argument string are passed directly to
    # ProcessStartInfo. No PowerShell or cmd.exe reparsing is introduced.
    $exitCode = [UserTaskManager.BackgroundProcessRunner]::Run(
        [string]$config.Executable,
        [string]$config.Arguments,
        [string]$config.WorkingDirectory,
        (Join-Path $logDirectory 'stdout.log'),
        (Join-Path $logDirectory 'stderr.log')
    )
}
catch {
    try {
        if (-not [IO.Directory]::Exists($logDirectory)) {
            [void][IO.Directory]::CreateDirectory($logDirectory)
        }
        $message = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $_.Exception.Message
        [IO.File]::AppendAllText($wrapperErrorPath, $message + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch {}
    $exitCode = 1
}
exit $exitCode
'@

$script:BackgroundVbsContent = @'
Option Explicit

Dim shell, fileSystem, scriptDirectory, wrapperPath, powershellPath, commandLine, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
wrapperPath = fileSystem.BuildPath(scriptDirectory, "wrapper.ps1")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
commandLine = QuoteArgument(powershellPath) & " -NoLogo -NoProfile -NonInteractive -File " & QuoteArgument(wrapperPath)

exitCode = shell.Run(commandLine, 0, True)
WScript.Quit exitCode

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
'@

function Write-AppLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
            [void][IO.Directory]::CreateDirectory($script:LogDirectory)
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch {
        # Logging must never terminate the GUI.
    }
}

function Release-ComObject {
    param([object]$InputObject)
    if ($null -ne $InputObject -and [Runtime.InteropServices.Marshal]::IsComObject($InputObject)) {
        try {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($InputObject)
        }
        catch {
            # The runtime will release it later if it is already disconnected.
        }
    }
}

function Get-FriendlyError {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = '操作'
    )

    $exception = $ErrorRecord.Exception
    $hresult = $exception.HResult
    if (($hresult -band 0xFFFFFFFF) -eq 0x80070005 -or
        $exception.Message -match 'Access.*denied|拒绝访问') {
        return '{0}失败：Access denied（拒绝访问）。当前用户令牌没有此任务或文件夹所需的权限。' -f $Context
    }
    if (($hresult -band 0xFFFFFFFF) -eq 0x8004130F) {
        return '{0}失败：任务不存在，可能已被其他程序删除。' -f $Context
    }
    if (($hresult -band 0xFFFFFFFF) -eq 0x80041315 -or
        $exception.Message -match 'service.*not.*running|服务未运行') {
        return '{0}失败：Task Scheduler 服务未运行或不可用。' -f $Context
    }
    return '{0}失败：{1} (HRESULT 0x{2:X8})' -f $Context, $exception.Message, ($hresult -band 0xFFFFFFFF)
}

function Show-ErrorMessage {
    param(
        [string]$Message,
        [string]$Title = 'UserTaskManager'
    )
    Write-AppLog -Level ERROR -Message $Message
    [void][Windows.MessageBox]::Show(
        $script:MainWindow,
        $Message,
        $Title,
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Error
    )
}

function Show-InfoMessage {
    param(
        [string]$Message,
        [string]$Title = 'UserTaskManager'
    )
    [void][Windows.MessageBox]::Show(
        $script:MainWindow,
        $Message,
        $Title,
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Information
    )
}

function Set-Status {
    param(
        [string]$Text,
        [int]$Count
    )
    if ($null -ne $script:StatusText) {
        $script:StatusText.Text = $Text
    }
    if ($PSBoundParameters.ContainsKey('Count') -and $null -ne $script:CountText) {
        $script:CountText.Text = '当前任务数：{0}' -f $Count
    }
}

function Set-Busy {
    param(
        [bool]$Busy,
        [string]$Status
    )
    $script:IsBusy = $Busy
    if ($null -ne $script:MainWindow) {
        $script:MainWindow.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { $null }
    }
    if ($null -ne $script:ActionPanel) {
        $script:ActionPanel.IsEnabled = -not $Busy
    }
    if ($null -ne $script:RefreshButton) {
        $script:RefreshButton.IsEnabled = -not $Busy
    }
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        Set-Status -Text $Status
    }
    if ($null -ne $script:MainWindow) {
        $script:MainWindow.Dispatcher.Invoke(
            [Action] {},
            [Windows.Threading.DispatcherPriority]::Background
        )
    }
}

function Connect-TaskService {
    if ($null -ne $script:TaskService) {
        try {
            if ($script:TaskService.Connected) {
                return
            }
        }
        catch {
            Release-ComObject $script:TaskService
            $script:TaskService = $null
        }
    }

    try {
        $script:TaskService = New-Object -ComObject 'Schedule.Service'
        $script:TaskService.Connect()
        Write-AppLog -Message ('已连接 Task Scheduler；用户={0}；SID={1}' -f $script:CurrentUserName, $script:CurrentSid)
    }
    catch {
        $message = Get-FriendlyError -ErrorRecord $_ -Context '连接 Task Scheduler'
        Write-AppLog -Level ERROR -Message $message
        Release-ComObject $script:TaskService
        $script:TaskService = $null
        throw $message
    }
}

function Normalize-FolderPath {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '\'
    }
    $value = $Path.Trim().Replace('/', '\')
    if (-not $value.StartsWith('\')) {
        $value = '\' + $value
    }
    while ($value.Contains('\\')) {
        $value = $value.Replace('\\', '\')
    }
    if ($value.Length -gt 1) {
        $value = $value.TrimEnd('\')
    }
    return $value
}

function Join-TaskFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$TaskName
    )
    $normalized = Normalize-FolderPath $FolderPath
    if ($normalized -eq '\') {
        return '\' + $TaskName
    }
    return $normalized + '\' + $TaskName
}

function Test-TaskName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return '任务名称不能为空。'
    }
    if ($Name -ne $Name.Trim()) {
        return '任务名称开头或结尾不能是空格。'
    }
    if ($Name.IndexOfAny([char[]]@('\', '/')) -ge 0) {
        return '任务名称不能包含反斜杠或正斜杠；文件夹请填写在 TaskPath。'
    }
    if ($Name.IndexOf([char]0) -ge 0) {
        return '任务名称包含无效字符。'
    }
    return $null
}

function Test-FolderPath {
    param([string]$Path)
    try {
        $normalized = Normalize-FolderPath $Path
        if ($normalized.IndexOf([char]0) -ge 0) {
            return 'TaskPath 包含无效字符。'
        }
        $segments = $normalized.Trim('\').Split([char]'\')
        foreach ($segment in $segments) {
            if ($normalized -ne '\' -and [string]::IsNullOrWhiteSpace($segment)) {
                return 'TaskPath 包含空文件夹名称。'
            }
        }
        return $null
    }
    catch {
        return 'TaskPath 无效。'
    }
}

function Get-NormalizedTaskFullPath {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    $parts = Split-RegisteredTaskPath $FullTaskPath
    $nameError = Test-TaskName $parts.Name
    if ($null -ne $nameError) { throw $nameError }
    return Join-TaskFullPath (Normalize-FolderPath $parts.Folder) $parts.Name
}

function Get-TaskPathHash {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    $normalizedIdentity = (Get-NormalizedTaskFullPath $FullTaskPath).ToUpperInvariant()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([Text.Encoding]::Unicode.GetBytes($normalizedIdentity))
        return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-BackgroundRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $script:LogDirectory 'Tasks'))
    $runtimeDirectory = [IO.Path]::GetFullPath((Join-Path $runtimeRoot (Get-TaskPathHash $FullTaskPath)))
    $requiredPrefix = $runtimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $runtimeDirectory.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '后台任务运行目录超出了 UserTaskManager Tasks 数据目录。'
    }
    return $runtimeDirectory
}

function Get-LegacyBackgroundRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    $parts = Split-RegisteredTaskPath $FullTaskPath
    if ($parts.Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    $runtimeRoot = [IO.Path]::GetFullPath($script:LogDirectory)
    $legacyDirectory = [IO.Path]::GetFullPath((Join-Path $runtimeRoot $parts.Name))
    $requiredPrefix = $runtimeRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $legacyDirectory.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $legacyDirectory
}

function New-BackgroundActionValues {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [Parameter(Mandatory = $true)][string]$Scheme
    )
    $runVbsPath = Join-Path $RuntimeDirectory 'run.vbs'
    $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    return [PSCustomObject]@{
        Scheme = $Scheme
        RuntimeDirectory = $RuntimeDirectory
        RunVbsPath = $runVbsPath
        WrapperPath = Join-Path $RuntimeDirectory 'wrapper.ps1'
        ConfigPath = Join-Path $RuntimeDirectory 'config.json'
        DefaultLogDirectory = Join-Path $RuntimeDirectory 'logs'
        WscriptPath = $wscriptPath
        ActionArguments = '//B //Nologo "{0}"' -f $runVbsPath
    }
}

function Get-BackgroundActionValues {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    return New-BackgroundActionValues -RuntimeDirectory (Get-BackgroundRuntimeDirectory $FullTaskPath) -Scheme 'HashedV2'
}

function Get-BackgroundActionCandidates {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $candidates.Add((Get-BackgroundActionValues $FullTaskPath))
    $legacyDirectory = Get-LegacyBackgroundRuntimeDirectory $FullTaskPath
    if (-not [string]::IsNullOrWhiteSpace($legacyDirectory)) {
        $candidates.Add((New-BackgroundActionValues -RuntimeDirectory $legacyDirectory -Scheme 'LegacyTaskName'))
    }
    return $candidates
}

function Resolve-BackgroundLogDirectory {
    param(
        [AllowEmptyString()][string]$RequestedPath,
        [Parameter(Mandatory = $true)][string]$DefaultPath
    )
    $defaultFullPath = [IO.Path]::GetFullPath($DefaultPath)
    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        return [PSCustomObject]@{ Path = $defaultFullPath; IsDefault = $true }
    }
    if ($RequestedPath.IndexOf([char]0) -ge 0) {
        throw '日志目录包含无效字符。'
    }
    $expandedPath = [Environment]::ExpandEnvironmentVariables($RequestedPath.Trim())
    if (-not [IO.Path]::IsPathRooted($expandedPath)) {
        throw '自定义日志目录必须是绝对路径。'
    }
    $customFullPath = [IO.Path]::GetFullPath($expandedPath)
    $customRoot = [IO.Path]::GetPathRoot($customFullPath)
    if (-not [string]::Equals($customFullPath, $customRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $customFullPath = $customFullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $defaultComparable = $defaultFullPath
    $defaultRoot = [IO.Path]::GetPathRoot($defaultComparable)
    if (-not [string]::Equals($defaultComparable, $defaultRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $defaultComparable = $defaultComparable.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    return [PSCustomObject]@{
        Path = $customFullPath
        IsDefault = [string]::Equals($customFullPath, $defaultComparable, [StringComparison]::OrdinalIgnoreCase)
    }
}

function Read-BackgroundConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not [IO.File]::Exists($ConfigPath)) { return $null }
    try {
        $json = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
        return $json | ConvertFrom-Json
    }
    catch {
        Write-AppLog -Level WARN -Message ('无法读取后台任务配置 {0}：{1}' -f $ConfigPath, $_.Exception.Message)
        return $null
    }
}

function Get-BackgroundRuntimeInfo {
    param(
        [Parameter(Mandatory = $true)][string]$FullTaskPath,
        [object]$Action
    )
    try {
        if ($null -ne $Action) {
            $expectedWscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            if (-not [string]::Equals([string]$Action.Path, $expectedWscriptPath, [StringComparison]::OrdinalIgnoreCase)) {
                return $null
            }
        }
        foreach ($values in @(Get-BackgroundActionCandidates $FullTaskPath)) {
            if ($null -ne $Action -and
                (-not [string]::Equals([string]$Action.Path, $values.WscriptPath, [StringComparison]::OrdinalIgnoreCase) -or
                 -not [string]::Equals([string]$Action.Arguments, $values.ActionArguments, [StringComparison]::OrdinalIgnoreCase))) {
                continue
            }
            $config = Read-BackgroundConfig $values.ConfigPath
            if ($null -eq $config -or $null -eq $config.PSObject.Properties['Version'] -or
                @(1, 2) -notcontains [int]$config.Version -or
                -not [string]::Equals([string]$config.TaskFullPath, $FullTaskPath, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $requestedLogDirectory = ''
            if ($null -ne $config.PSObject.Properties['LogDirectory']) {
                $requestedLogDirectory = [string]$config.LogDirectory
            }
            $resolvedLog = Resolve-BackgroundLogDirectory -RequestedPath $requestedLogDirectory -DefaultPath $values.DefaultLogDirectory
            return [PSCustomObject]@{
                FullTaskPath = $FullTaskPath
                Scheme = $values.Scheme
                RuntimeDirectory = $values.RuntimeDirectory
                RunVbsPath = $values.RunVbsPath
                WrapperPath = $values.WrapperPath
                ConfigPath = $values.ConfigPath
                DefaultLogDirectory = $values.DefaultLogDirectory
                LogDirectory = $resolvedLog.Path
                LogDirectoryIsDefault = $resolvedLog.IsDefault
                StdOutPath = Join-Path $resolvedLog.Path 'stdout.log'
                StdErrPath = Join-Path $resolvedLog.Path 'stderr.log'
                WrapperErrorPath = Join-Path $resolvedLog.Path 'wrapper-error.log'
                WscriptPath = $values.WscriptPath
                ActionArguments = $values.ActionArguments
                Config = $config
            }
        }
        return $null
    }
    catch {
        Write-AppLog -Level WARN -Message ('识别后台任务 {0} 失败：{1}' -f $FullTaskPath, $_.Exception.Message)
        return $null
    }
}

function Test-ActionTargetsBackgroundRunner {
    param(
        [Parameter(Mandatory = $true)][string]$FullTaskPath,
        [Parameter(Mandatory = $true)][object]$Action
    )
    try {
        foreach ($values in @(Get-BackgroundActionCandidates $FullTaskPath)) {
            if ([string]::Equals([string]$Action.Path, $values.WscriptPath, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$Action.Arguments, $values.ActionArguments, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        return $false
    }
    catch {
        return $false
    }
}

function Restore-BackgroundRuntimeState {
    param([object]$State)
    if ($null -eq $State) { return }
    foreach ($entry in $State.PreviousFiles) {
        try {
            if ($entry.Existed) {
                [IO.File]::WriteAllBytes($entry.Path, $entry.Bytes)
            }
            elseif ([IO.File]::Exists($entry.Path)) {
                [IO.File]::Delete($entry.Path)
            }
        }
        catch {
            Write-AppLog -Level WARN -Message ('回滚后台运行文件失败 {0}：{1}' -f $entry.Path, $_.Exception.Message)
        }
    }
    if ($null -ne $State.PSObject.Properties['CreatedLogDirectory'] -and $State.CreatedLogDirectory -and
        $null -ne $State.PSObject.Properties['LogDirectory']) {
        try {
            if ([IO.Directory]::Exists($State.LogDirectory) -and
                [IO.Directory]::GetFileSystemEntries($State.LogDirectory).Count -eq 0) {
                [IO.Directory]::Delete($State.LogDirectory, $false)
            }
        }
        catch {}
    }
    if ($State.CreatedDirectory) {
        try {
            if ([IO.Directory]::Exists($State.RuntimeDirectory)) {
                [IO.Directory]::Delete($State.RuntimeDirectory, $true)
            }
        }
        catch {}
    }
}

function Install-BackgroundRuntime {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$FullTaskPath,
        [string]$OriginalFullPath
    )
    $values = Get-BackgroundActionValues $FullTaskPath
    $existingConfig = Read-BackgroundConfig $values.ConfigPath
    if ($null -ne $existingConfig -and
        -not [string]::Equals([string]$existingConfig.TaskFullPath, $FullTaskPath, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]::IsNullOrWhiteSpace($OriginalFullPath) -or
            -not [string]::Equals([string]$existingConfig.TaskFullPath, $OriginalFullPath, [StringComparison]::OrdinalIgnoreCase))) {
        throw ("后台运行目录已由另一个任务使用：{0}`n现有任务：{1}" -f $values.RuntimeDirectory, $existingConfig.TaskFullPath)
    }

    $createdDirectory = -not [IO.Directory]::Exists($values.RuntimeDirectory)
    if ($createdDirectory) {
        [void][IO.Directory]::CreateDirectory($values.RuntimeDirectory)
    }
    $requestedLogDirectory = ''
    if ($null -ne $Data.PSObject.Properties['LogDirectory']) {
        $requestedLogDirectory = [string]$Data.LogDirectory
    }
    $resolvedLog = Resolve-BackgroundLogDirectory -RequestedPath $requestedLogDirectory -DefaultPath $values.DefaultLogDirectory
    $createdLogDirectory = -not [IO.Directory]::Exists($resolvedLog.Path)
    if ($createdLogDirectory) {
        [void][IO.Directory]::CreateDirectory($resolvedLog.Path)
    }

    $managedPaths = @($values.WrapperPath, $values.RunVbsPath, $values.ConfigPath)
    $previousFiles = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $managedPaths) {
        $exists = [IO.File]::Exists($path)
        $previousFiles.Add([PSCustomObject]@{
            Path = $path
            Existed = $exists
            Bytes = if ($exists) { [IO.File]::ReadAllBytes($path) } else { $null }
        })
    }
    $state = [PSCustomObject]@{
        RuntimeDirectory = $values.RuntimeDirectory
        CreatedDirectory = $createdDirectory
        LogDirectory = $resolvedLog.Path
        CreatedLogDirectory = $createdLogDirectory
        PreviousFiles = $previousFiles
        Values = $values
    }

    try {
        $config = [ordered]@{
            Version = 2
            TaskFullPath = $FullTaskPath
            TaskName = [string]$Data.TaskName
            Executable = [string]$Data.Program
            Arguments = [string]$Data.Arguments
            WorkingDirectory = [string]$Data.WorkingDirectory
            LogDirectory = $resolvedLog.Path
            LogDirectoryIsDefault = $resolvedLog.IsDefault
        }
        $configJson = $config | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($values.WrapperPath, $script:BackgroundWrapperContent, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText($values.RunVbsPath, $script:BackgroundVbsContent, [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText($values.ConfigPath, $configJson, (New-Object Text.UTF8Encoding($true)))
        Write-AppLog -Message ('已部署后台运行文件：{0}' -f $values.RuntimeDirectory)
        return $state
    }
    catch {
        Restore-BackgroundRuntimeState $state
        throw
    }
}

function Remove-BackgroundRuntimeFiles {
    param(
        [Parameter(Mandatory = $true)][object]$RuntimeInfo,
        [bool]$DeleteLogs = $false
    )
    $runtimeDirectory = [IO.Path]::GetFullPath([string]$RuntimeInfo.RuntimeDirectory)
    $allowedRuntimeDirectory = $false
    foreach ($candidate in @(Get-BackgroundActionCandidates $RuntimeInfo.FullTaskPath)) {
        if ([string]::Equals($runtimeDirectory, [IO.Path]::GetFullPath($candidate.RuntimeDirectory), [StringComparison]::OrdinalIgnoreCase)) {
            $allowedRuntimeDirectory = $true
            break
        }
    }
    if (-not $allowedRuntimeDirectory) {
        throw '拒绝清理：后台运行目录与完整任务路径不匹配。'
    }

    foreach ($path in @($RuntimeInfo.WrapperPath, $RuntimeInfo.RunVbsPath, $RuntimeInfo.ConfigPath)) {
        if ([IO.File]::Exists($path)) {
            [IO.File]::Delete($path)
        }
    }
    if ($DeleteLogs -and [IO.Directory]::Exists($RuntimeInfo.LogDirectory)) {
        $logDirectory = [IO.Path]::GetFullPath([string]$RuntimeInfo.LogDirectory)
        $lastDeleteError = $null
        if ([bool]$RuntimeInfo.LogDirectoryIsDefault) {
            $expectedLogDirectory = [IO.Path]::GetFullPath((Join-Path $runtimeDirectory 'logs'))
            if (-not [string]::Equals($logDirectory, $expectedLogDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                throw '拒绝清理：默认日志目录不在预期的后台运行目录中。'
            }
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                try {
                    if ([IO.Directory]::Exists($expectedLogDirectory)) {
                        [IO.Directory]::Delete($expectedLogDirectory, $true)
                    }
                    $lastDeleteError = $null
                    break
                }
                catch [IO.IOException] {
                    $lastDeleteError = $_
                    Start-Sleep -Milliseconds 250
                }
                catch [UnauthorizedAccessException] {
                    $lastDeleteError = $_
                    Start-Sleep -Milliseconds 250
                }
            }
        }
        else {
            # A custom directory may contain unrelated data. Delete only the
            # three files owned by this background task, never the whole tree.
            foreach ($logFileName in @('stdout.log', 'stderr.log', 'wrapper-error.log')) {
                $logFilePath = Join-Path $logDirectory $logFileName
                for ($attempt = 1; $attempt -le 20; $attempt++) {
                    try {
                        if ([IO.File]::Exists($logFilePath)) { [IO.File]::Delete($logFilePath) }
                        $lastDeleteError = $null
                        break
                    }
                    catch [IO.IOException] {
                        $lastDeleteError = $_
                        Start-Sleep -Milliseconds 250
                    }
                    catch [UnauthorizedAccessException] {
                        $lastDeleteError = $_
                        Start-Sleep -Milliseconds 250
                    }
                }
                if ($null -ne $lastDeleteError) { break }
            }
            if ($null -eq $lastDeleteError -and [IO.Directory]::Exists($logDirectory) -and
                [IO.Directory]::GetFileSystemEntries($logDirectory).Count -eq 0) {
                try { [IO.Directory]::Delete($logDirectory, $false) } catch {}
            }
        }
        if ($null -ne $lastDeleteError) {
            throw ('日志仍被后台进程占用，请停止任务后手动删除：{0}；{1}' -f $logDirectory, $lastDeleteError.Exception.Message)
        }
    }
    if ([IO.Directory]::Exists($runtimeDirectory) -and
        [IO.Directory]::GetFileSystemEntries($runtimeDirectory).Count -eq 0) {
        $runtimeDeleteError = $null
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            try {
                if ([IO.Directory]::Exists($runtimeDirectory) -and
                    [IO.Directory]::GetFileSystemEntries($runtimeDirectory).Count -eq 0) {
                    [IO.Directory]::Delete($runtimeDirectory, $false)
                }
                $runtimeDeleteError = $null
                break
            }
            catch [IO.IOException] {
                $runtimeDeleteError = $_
                Start-Sleep -Milliseconds 250
            }
            catch [UnauthorizedAccessException] {
                $runtimeDeleteError = $_
                Start-Sleep -Milliseconds 250
            }
        }
        if ($null -ne $runtimeDeleteError) {
            Write-AppLog -Level WARN -Message ('后台文件已清理，但空目录暂时被占用并保留：{0}' -f $runtimeDirectory)
        }
    }
    Write-AppLog -Message ('已清理后台运行脚本；目录={0}；删除日志={1}' -f $runtimeDirectory, $DeleteLogs)
}

function Get-StateText {
    param([int]$State)
    switch ($State) {
        0 { '未知' }
        1 { '已禁用' }
        2 { '已排队' }
        3 { '就绪' }
        4 { '正在运行' }
        default { '状态 {0}' -f $State }
    }
}

function Format-TaskDate {
    param([object]$Value)
    if ($null -eq $Value) { return '—' }
    try {
        $date = [DateTime]$Value
        if ($date.Year -le 1900) { return '—' }
        return $date.ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        return '—'
    }
}

function Format-LastResult {
    param([int]$Result)
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($Result), 0)
    if ($Result -eq 0) {
        return '成功 (0x00000000)'
    }
    return '{0} (0x{1:X8})' -f $Result, $unsigned
}

function Convert-IsoDurationToText {
    param([string]$Duration)
    if ([string]::IsNullOrWhiteSpace($Duration)) { return $null }
    if ($Duration -match '^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$') {
        $parts = New-Object 'System.Collections.Generic.List[string]'
        if ($matches[1]) { $parts.Add(('{0}小时' -f $matches[1])) }
        if ($matches[2]) { $parts.Add(('{0}分钟' -f $matches[2])) }
        if ($matches[3]) { $parts.Add(('{0}秒' -f $matches[3])) }
        return ($parts -join '')
    }
    return $Duration
}

function Get-TriggerSummary {
    param([object]$Definition)
    $summaries = New-Object 'System.Collections.Generic.List[string]'
    $triggers = $null
    try {
        $triggers = $Definition.Triggers
        foreach ($trigger in @($triggers)) {
            try {
                $text = switch ([int]$trigger.Type) {
                    1 { '单次 {0}' -f (Format-TaskDate $trigger.StartBoundary) }
                    2 { '每天 {0}' -f (Format-TaskDate $trigger.StartBoundary) }
                    3 { '每周' }
                    4 { '每月' }
                    5 { '每月（星期）' }
                    6 { '空闲时' }
                    7 { '注册时' }
                    8 { '启动时' }
                    9 { '用户登录时' }
                    11 { '事件触发' }
                    default { '触发器类型 {0}' -f $trigger.Type }
                }
                try {
                    if (-not [string]::IsNullOrWhiteSpace([string]$trigger.Repetition.Interval)) {
                        $text += '；每隔' + (Convert-IsoDurationToText ([string]$trigger.Repetition.Interval)) + '重复'
                    }
                }
                catch {}
                if (-not [bool]$trigger.Enabled) {
                    $text += '（禁用）'
                }
                $summaries.Add($text)
            }
            catch {
                $summaries.Add('无法读取的触发器')
            }
            finally {
                Release-ComObject $trigger
            }
        }
    }
    finally {
        Release-ComObject $triggers
    }
    if ($summaries.Count -eq 0) { return '无触发器' }
    return ($summaries -join '；')
}

function Quote-SummaryArgument {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value -match '\s') { return '"{0}"' -f $Value }
    return $Value
}

function Get-ActionSummary {
    param([object]$Definition)
    $summaries = New-Object 'System.Collections.Generic.List[string]'
    $actions = $null
    try {
        $actions = $Definition.Actions
        foreach ($action in @($actions)) {
            try {
                if ([int]$action.Type -eq $script:TASK_ACTION_EXEC) {
                    $summary = Quote-SummaryArgument ([string]$action.Path)
                    if (-not [string]::IsNullOrWhiteSpace([string]$action.Arguments)) {
                        $summary += ' ' + [string]$action.Arguments
                    }
                    $summaries.Add($summary)
                }
                else {
                    $summaries.Add(('不支持的操作类型 {0}' -f $action.Type))
                }
            }
            catch {
                $summaries.Add('无法读取的操作')
            }
            finally {
                Release-ComObject $action
            }
        }
    }
    finally {
        Release-ComObject $actions
    }
    if ($summaries.Count -eq 0) { return '无操作' }
    return ($summaries -join '；')
}

function Get-DisplayActionSummary {
    param(
        [Parameter(Mandatory = $true)][object]$Definition,
        [Parameter(Mandatory = $true)][string]$FullTaskPath
    )
    $actions = $null
    $action = $null
    try {
        $actions = $Definition.Actions
        if ([int]$actions.Count -eq 1) {
            $action = $actions.Item(1)
            $runtimeInfo = Get-BackgroundRuntimeInfo -FullTaskPath $FullTaskPath -Action $action
            if ($null -ne $runtimeInfo) {
                $summary = '后台应用：' + (Quote-SummaryArgument ([string]$runtimeInfo.Config.Executable))
                if (-not [string]::IsNullOrWhiteSpace([string]$runtimeInfo.Config.Arguments)) {
                    $summary += ' ' + [string]$runtimeInfo.Config.Arguments
                }
                return $summary + '；日志：' + $runtimeInfo.LogDirectory
            }
        }
    }
    finally {
        Release-ComObject $action
        Release-ComObject $actions
    }
    return Get-ActionSummary $Definition
}

function Convert-RegisteredTaskToModel {
    param([object]$RegisteredTask)
    $definition = $null
    $principal = $null
    try {
        $definition = $RegisteredTask.Definition
        $principal = $definition.Principal
        $description = [string]$definition.RegistrationInfo.Description
        return [PSCustomObject]@{
            Name = [string]$RegisteredTask.Name
            Path = [string]$RegisteredTask.Path
            State = Get-StateText ([int]$RegisteredTask.State)
            Enabled = [bool]$RegisteredTask.Enabled
            RunAs = [string]$principal.UserId
            LastRun = Format-TaskDate $RegisteredTask.LastRunTime
            NextRun = Format-TaskDate $RegisteredTask.NextRunTime
            LastResult = Format-LastResult ([int]$RegisteredTask.LastTaskResult)
            Triggers = Get-TriggerSummary $definition
            Actions = Get-DisplayActionSummary -Definition $definition -FullTaskPath ([string]$RegisteredTask.Path)
            Description = $description
        }
    }
    finally {
        Release-ComObject $principal
        Release-ComObject $definition
    }
}

function Get-FolderTaskModels {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )
    Connect-TaskService
    $models = New-Object 'System.Collections.Generic.List[object]'
    $folder = $null
    $tasks = $null
    try {
        $folder = $script:TaskService.GetFolder($FolderPath)
        $tasks = $folder.GetTasks($script:TASK_ENUM_HIDDEN)
        foreach ($task in @($tasks)) {
            try {
                $models.Add((Convert-RegisteredTaskToModel $task))
            }
            catch {
                $name = try { [string]$task.Name } catch { '<未知任务>' }
                $message = Get-FriendlyError -ErrorRecord $_ -Context ('读取任务 {0}' -f $name)
                Write-AppLog -Level WARN -Message $message
            }
            finally {
                Release-ComObject $task
            }
        }
    }
    finally {
        Release-ComObject $tasks
        Release-ComObject $folder
    }
    return $models
}

function Add-FolderTreeNodes {
    param(
        [object]$Folder,
        [Windows.Controls.TreeViewItem]$ParentNode,
        [System.Collections.Generic.List[string]]$Errors
    )
    $children = $null
    try {
        $children = $Folder.GetFolders(0)
        foreach ($child in @($children)) {
            try {
                $path = [string]$child.Path
                $node = New-Object Windows.Controls.TreeViewItem
                $node.Header = [string]$child.Name
                $node.Tag = $path
                [void]$ParentNode.Items.Add($node)
                $script:FolderPaths.Add($path)
                Add-FolderTreeNodes -Folder $child -ParentNode $node -Errors $Errors
            }
            catch {
                $contextPath = try { [string]$child.Path } catch { '<未知文件夹>' }
                $message = Get-FriendlyError -ErrorRecord $_ -Context ('枚举文件夹 {0}' -f $contextPath)
                $Errors.Add($message)
                Write-AppLog -Level WARN -Message $message
            }
            finally {
                Release-ComObject $child
            }
        }
    }
    catch {
        $folderPath = try { [string]$Folder.Path } catch { '<未知文件夹>' }
        $message = Get-FriendlyError -ErrorRecord $_ -Context ('枚举文件夹 {0}' -f $folderPath)
        $Errors.Add($message)
        Write-AppLog -Level WARN -Message $message
    }
    finally {
        Release-ComObject $children
    }
}

function Find-TreeNodeByPath {
    param(
        [Windows.Controls.ItemsControl]$Parent,
        [string]$Path
    )
    foreach ($item in $Parent.Items) {
        if ([string]$item.Tag -eq $Path) {
            Write-Output -NoEnumerate $item
            return
        }
        $found = Find-TreeNodeByPath -Parent $item -Path $Path
        if ($null -ne $found) {
            Write-Output -NoEnumerate $found
            return
        }
    }
    return $null
}

function Refresh-FolderTree {
    $previous = $script:CurrentFolderPath
    $script:FolderTree.Items.Clear()
    $script:FolderPaths.Clear()
    Connect-TaskService

    $rootFolder = $null
    $errors = New-Object 'System.Collections.Generic.List[string]'
    try {
        $rootFolder = $script:TaskService.GetFolder('\')
        $rootNode = New-Object Windows.Controls.TreeViewItem
        $rootNode.Header = '任务计划程序库'
        $rootNode.Tag = '\'
        $rootNode.IsExpanded = $true
        [void]$script:FolderTree.Items.Add($rootNode)
        $script:FolderPaths.Add('\')
        Add-FolderTreeNodes -Folder $rootFolder -ParentNode $rootNode -Errors $errors

        $target = Find-TreeNodeByPath -Parent $script:FolderTree -Path $previous
        if ($null -eq $target) { $target = $rootNode }
        Write-AppLog -Message ('选择 TreeView 节点；类型={0}；路径={1}' -f $target.GetType().FullName, $previous)
        $target.SetValue([Windows.Controls.TreeViewItem]::IsSelectedProperty, $true)
        $target.BringIntoView()
    }
    finally {
        Release-ComObject $rootFolder
    }
    return $errors
}

function Update-TaskDetails {
    $task = $script:TaskGrid.SelectedItem
    if ($null -eq $task) {
        $script:DetailText.Text = '请选择一个任务。'
        return
    }
    $script:DetailText.Text = @"
任务名称：$($task.Name)
完整路径：$($task.Path)
当前状态：$($task.State)
是否启用：$($task.Enabled)
运行账户：$($task.RunAs)
上次运行：$($task.LastRun)
下次运行：$($task.NextRun)
上次结果：$($task.LastResult)

触发器：
$($task.Triggers)

操作：
$($task.Actions)

描述：
$($task.Description)
"@
}

function Refresh-TaskList {
    param([string]$FolderPath)
    if ($script:IsBusy) { return }
    Set-Busy -Busy $true -Status ('正在读取 {0} ...' -f $FolderPath)
    try {
        $script:CurrentFolderPath = Normalize-FolderPath $FolderPath
        $models = @(Get-FolderTaskModels -FolderPath $script:CurrentFolderPath)
        $script:TaskGrid.ItemsSource = $models
        Update-TaskDetails
        Set-Status -Text ('已刷新 {0}' -f $script:CurrentFolderPath) -Count $models.Count
    }
    catch {
        $message = if ($_.Exception.Message -match '^读取|^连接|失败：') {
            $_.Exception.Message
        }
        else {
            Get-FriendlyError -ErrorRecord $_ -Context ('读取文件夹 {0}' -f $FolderPath)
        }
        Show-ErrorMessage $message
        Set-Status -Text $message -Count 0
    }
    finally {
        Set-Busy -Busy $false
    }
}

function Refresh-All {
    if ($script:IsBusy) { return }
    Set-Busy -Busy $true -Status '正在刷新任务文件夹...'
    try {
        $errors = @(Refresh-FolderTree)
        $path = $script:CurrentFolderPath
        $models = @(Get-FolderTaskModels -FolderPath $path)
        $script:TaskGrid.ItemsSource = $models
        Update-TaskDetails
        if ($errors.Count -gt 0) {
            Set-Status -Text ('刷新完成；跳过 {0} 个无法枚举的文件夹，详见日志。' -f $errors.Count) -Count $models.Count
        }
        else {
            Set-Status -Text ('刷新完成：{0}' -f $path) -Count $models.Count
        }
    }
    catch {
        $message = if ($_.Exception.Message -match '失败：') {
            $_.Exception.Message
        }
        else {
            Get-FriendlyError -ErrorRecord $_ -Context '刷新'
        }
        Show-ErrorMessage $message
        Set-Status -Text $message -Count 0
    }
    finally {
        Set-Busy -Busy $false
    }
}

function Split-RegisteredTaskPath {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    $lastSlash = $FullPath.LastIndexOf('\')
    if ($lastSlash -le 0) {
        return [PSCustomObject]@{ Folder = '\'; Name = $FullPath.TrimStart('\') }
    }
    return [PSCustomObject]@{
        Folder = $FullPath.Substring(0, $lastSlash)
        Name = $FullPath.Substring($lastSlash + 1)
    }
}

function Invoke-WithSelectedTask {
    param(
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][ScriptBlock]$Operation
    )
    if ($script:IsBusy) { return }
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }

    Set-Busy -Busy $true -Status ('正在{0} {1} ...' -f $OperationName, $selected.Path)
    $folder = $null
    $task = $null
    try {
        Connect-TaskService
        $parts = Split-RegisteredTaskPath $selected.Path
        $folder = $script:TaskService.GetFolder($parts.Folder)
        $task = $folder.GetTask($parts.Name)
        & $Operation $folder $task $selected
        $message = '{0}成功：{1}' -f $OperationName, $selected.Path
        Write-AppLog -Message $message
        Set-Status -Text $message
        $models = @(Get-FolderTaskModels -FolderPath $script:CurrentFolderPath)
        $script:TaskGrid.ItemsSource = $models
        Set-Status -Text $message -Count $models.Count
    }
    catch {
        $message = Get-FriendlyError -ErrorRecord $_ -Context ('{0} {1}' -f $OperationName, $selected.Path)
        Show-ErrorMessage $message
        Set-Status -Text $message
    }
    finally {
        Release-ComObject $task
        Release-ComObject $folder
        Set-Busy -Busy $false
    }
}

function Get-RegisteredTaskXml {
    param([string]$FullPath)
    Connect-TaskService
    $parts = Split-RegisteredTaskPath $FullPath
    $folder = $null
    $task = $null
    try {
        $folder = $script:TaskService.GetFolder($parts.Folder)
        $task = $folder.GetTask($parts.Name)
        return [string]$task.Xml
    }
    finally {
        Release-ComObject $task
        Release-ComObject $folder
    }
}

function Get-RegisteredTaskBackgroundInfo {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    Connect-TaskService
    $parts = Split-RegisteredTaskPath $FullPath
    $folder = $null
    $task = $null
    $definition = $null
    $actions = $null
    $action = $null
    try {
        $folder = $script:TaskService.GetFolder($parts.Folder)
        $task = $folder.GetTask($parts.Name)
        $definition = $task.Definition
        $actions = $definition.Actions
        if ([int]$actions.Count -ne 1) { return $null }
        $action = $actions.Item(1)
        return Get-BackgroundRuntimeInfo -FullTaskPath $FullPath -Action $action
    }
    finally {
        Release-ComObject $action
        Release-ComObject $actions
        Release-ComObject $definition
        Release-ComObject $task
        Release-ComObject $folder
    }
}

function Open-DirectoryInExplorer {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($fullPath)) {
        [void][IO.Directory]::CreateDirectory($fullPath)
    }
    $explorerPath = Join-Path $env:SystemRoot 'explorer.exe'
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $explorerPath
    $startInfo.Arguments = '"{0}"' -f $fullPath.Replace('"', '""')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    [void][Diagnostics.Process]::Start($startInfo)
}

function Show-XmlWindow {
    param(
        [string]$TaskPath,
        [string]$Xml
    )
    $window = New-Object Windows.Window
    $window.Title = '任务 XML - ' + $TaskPath
    $window.Owner = $script:MainWindow
    $window.Width = 900
    $window.Height = 650
    $window.WindowStartupLocation = 'CenterOwner'

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = 10
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = New-Object Windows.GridLength(1, 'Star') }))
    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = [Windows.GridLength]::Auto }))

    $textBox = New-Object Windows.Controls.TextBox
    $textBox.Text = $Xml
    $textBox.IsReadOnly = $true
    $textBox.AcceptsReturn = $true
    $textBox.AcceptsTab = $true
    $textBox.TextWrapping = 'NoWrap'
    $textBox.VerticalScrollBarVisibility = 'Auto'
    $textBox.HorizontalScrollBarVisibility = 'Auto'
    $textBox.FontFamily = 'Consolas'
    $textBox.FontSize = 13
    [Windows.Controls.Grid]::SetRow($textBox, 0)
    [void]$grid.Children.Add($textBox)

    $closeButton = New-Object Windows.Controls.Button
    $closeButton.Content = '关闭'
    $closeButton.Width = 90
    $closeButton.Margin = '0,10,0,0'
    $closeButton.HorizontalAlignment = 'Right'
    $closeButton.Add_Click({ $window.Close() })
    [Windows.Controls.Grid]::SetRow($closeButton, 1)
    [void]$grid.Children.Add($closeButton)

    $window.Content = $grid
    [void]$window.ShowDialog()
}

function Get-TaskEditData {
    param([string]$FullPath)
    Connect-TaskService
    $parts = Split-RegisteredTaskPath $FullPath
    $folder = $null
    $task = $null
    $definition = $null
    $actions = $null
    $triggers = $null
    $principal = $null
    $action = $null
    $trigger = $null
    $backgroundInfo = $null
    try {
        $folder = $script:TaskService.GetFolder($parts.Folder)
        $task = $folder.GetTask($parts.Name)
        $definition = $task.Definition
        $actions = $definition.Actions
        $triggers = $definition.Triggers
        $principal = $definition.Principal

        $reasons = New-Object 'System.Collections.Generic.List[string]'
        if ([int]$actions.Count -ne 1) {
            $reasons.Add('操作数量不是 1')
        }
        else {
            $action = $actions.Item(1)
            if ([int]$action.Type -ne $script:TASK_ACTION_EXEC) {
                $reasons.Add('操作不是 Exec 程序操作')
            }
        }

        if ([int]$triggers.Count -ne 1) {
            $reasons.Add('触发器数量不是 1')
        }
        else {
            $trigger = $triggers.Item(1)
            if (@($script:TASK_TRIGGER_TIME, $script:TASK_TRIGGER_DAILY, $script:TASK_TRIGGER_LOGON) -notcontains [int]$trigger.Type) {
                $reasons.Add('触发器类型不受支持')
            }
        }

        if ([int]$principal.RunLevel -ne $script:TASK_RUNLEVEL_LUA) {
            $reasons.Add('任务使用最高权限运行')
        }
        if ([int]$principal.LogonType -ne $script:TASK_LOGON_INTERACTIVE_TOKEN) {
            $reasons.Add('登录类型不是 InteractiveToken')
        }

        # Reject structures that this editor cannot faithfully represent.
        $xml = [xml]([string]$task.Xml)
        $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $unsupportedTriggerNodes = @($xml.SelectNodes(
            '/t:Task/t:Triggers/*[not(self::t:TimeTrigger or self::t:CalendarTrigger or self::t:LogonTrigger)]',
            $ns
        ))
        if ($unsupportedTriggerNodes.Count -gt 0) {
            $reasons.Add('XML 中包含高级触发器')
        }
        $unsupportedActionNodes = @($xml.SelectNodes(
            '/t:Task/t:Actions/*[not(self::t:Exec)]',
            $ns
        ))
        if ($unsupportedActionNodes.Count -gt 0) {
            $reasons.Add('XML 中包含 COM Handler、邮件或其他高级操作')
        }
        $triggerNode = $xml.SelectSingleNode('/t:Task/t:Triggers/*', $ns)
        if ($null -ne $triggerNode) {
            $allowedTriggerChildren = switch ($triggerNode.LocalName) {
                'TimeTrigger' { @('Repetition', 'StartBoundary', 'Enabled') }
                'CalendarTrigger' { @('Repetition', 'StartBoundary', 'Enabled', 'ScheduleByDay') }
                'LogonTrigger' { @('StartBoundary', 'EndBoundary', 'Enabled', 'UserId') }
                default { @() }
            }
            foreach ($child in @($triggerNode.ChildNodes)) {
                if ($child.NodeType -eq [Xml.XmlNodeType]::Element -and
                    $allowedTriggerChildren -notcontains $child.LocalName) {
                    $reasons.Add(('触发器属性 {0} 不受支持' -f $child.LocalName))
                }
            }
            if ($triggerNode.LocalName -eq 'CalendarTrigger') {
                $calendarChildren = @($triggerNode.SelectNodes(
                    't:ScheduleByDay/*[not(self::t:DaysInterval)]',
                    $ns
                ))
                if ($calendarChildren.Count -gt 0) {
                    $reasons.Add('日历触发器包含非每日计划')
                }
            }
        }
        $settingsNode = $xml.SelectSingleNode('/t:Task/t:Settings', $ns)
        if ($null -ne $settingsNode) {
            $allowedSettings = @(
                'MultipleInstancesPolicy', 'DisallowStartIfOnBatteries', 'StopIfGoingOnBatteries',
                'AllowHardTerminate', 'StartWhenAvailable', 'RunOnlyIfNetworkAvailable',
                'IdleSettings', 'AllowStartOnDemand', 'Enabled', 'Hidden', 'RunOnlyIfIdle',
                'WakeToRun', 'ExecutionTimeLimit', 'Priority', 'RestartOnFailure',
                'UseUnifiedSchedulingEngine', 'DisallowStartOnRemoteAppSession',
                'MaintenanceSettings', 'DeleteExpiredTaskAfter', 'Volatile'
            )
            foreach ($child in @($settingsNode.ChildNodes)) {
                if ($child.NodeType -eq [Xml.XmlNodeType]::Element -and $allowedSettings -notcontains $child.LocalName) {
                    $reasons.Add(('设置 {0} 不受支持' -f $child.LocalName))
                }
            }
        }

        if ($null -ne $action) {
            $backgroundInfo = Get-BackgroundRuntimeInfo -FullTaskPath $FullPath -Action $action
            if ($null -eq $backgroundInfo -and (Test-ActionTargetsBackgroundRunner -FullTaskPath $FullPath -Action $action)) {
                $reasons.Add('后台运行配置缺失或与任务路径不匹配')
            }
        }

        if ($reasons.Count -gt 0) {
            return [PSCustomObject]@{
                Supported = $false
                Reason = '包含不支持的高级配置：' + ($reasons -join '；')
            }
        }

        $triggerKind = switch ([int]$trigger.Type) {
            9 { '登录时' }
            2 { '每天' }
            default { '单次' }
        }
        $start = Get-Date
        if ([int]$trigger.Type -ne $script:TASK_TRIGGER_LOGON) {
            try { $start = [DateTime]$trigger.StartBoundary } catch {}
        }
        $repeatMinutes = 0
        try {
            $interval = [string]$trigger.Repetition.Interval
            if ($interval -match '^PT(\d+)M$') {
                $repeatMinutes = [int]$matches[1]
            }
            elseif (-not [string]::IsNullOrWhiteSpace($interval)) {
                return [PSCustomObject]@{
                    Supported = $false
                    Reason = '包含不支持的高级配置：重复间隔无法由编辑器表示。'
                }
            }
        }
        catch {}

        $displayProgram = [string]$action.Path
        $displayArguments = [string]$action.Arguments
        $displayWorkingDirectory = [string]$action.WorkingDirectory
        $backgroundMode = $false
        $displayLogDirectory = ''
        if ($null -ne $backgroundInfo) {
            $displayProgram = [string]$backgroundInfo.Config.Executable
            $displayArguments = [string]$backgroundInfo.Config.Arguments
            $displayWorkingDirectory = [string]$backgroundInfo.Config.WorkingDirectory
            $backgroundMode = $true
            if (-not [bool]$backgroundInfo.LogDirectoryIsDefault) {
                $displayLogDirectory = [string]$backgroundInfo.LogDirectory
            }
        }

        return [PSCustomObject]@{
            Supported = $true
            FullPath = $FullPath
            TaskPath = $parts.Folder
            TaskName = $parts.Name
            Description = [string]$definition.RegistrationInfo.Description
            Enabled = [bool]$task.Enabled
            Program = $displayProgram
            Arguments = $displayArguments
            WorkingDirectory = $displayWorkingDirectory
            BackgroundMode = $backgroundMode
            LogDirectory = $displayLogDirectory
            TriggerKind = $triggerKind
            StartDate = $start.Date
            StartTime = $start.ToString('HH:mm')
            RepeatMinutes = $repeatMinutes
        }
    }
    finally {
        Release-ComObject $trigger
        Release-ComObject $action
        Release-ComObject $principal
        Release-ComObject $triggers
        Release-ComObject $actions
        Release-ComObject $definition
        Release-ComObject $task
        Release-ComObject $folder
    }
}

function Ensure-TaskFolder {
    param([string]$FolderPath)
    Connect-TaskService
    $normalized = Normalize-FolderPath $FolderPath
    $existing = $null
    try {
        $existing = $script:TaskService.GetFolder($normalized)
        return $existing
    }
    catch {
        if ($normalized -eq '\') { throw }
    }

    $parent = $null
    try {
        $parent = $script:TaskService.GetFolder('\')
        $currentPath = '\'
        foreach ($segment in $normalized.Trim('\').Split([char]'\')) {
            if ([string]::IsNullOrWhiteSpace($segment)) { continue }
            $nextPath = if ($currentPath -eq '\') { '\' + $segment } else { $currentPath + '\' + $segment }
            $nextFolder = $null
            try {
                $nextFolder = $script:TaskService.GetFolder($nextPath)
            }
            catch {
                try {
                    $nextFolder = $parent.CreateFolder($segment, $null)
                    Write-AppLog -Message ('已创建任务文件夹 {0}' -f $nextPath)
                }
                catch {
                    $message = Get-FriendlyError -ErrorRecord $_ -Context ('创建任务文件夹 {0}' -f $nextPath)
                    throw $message
                }
            }
            Release-ComObject $parent
            $parent = $nextFolder
            $currentPath = $nextPath
        }
        $result = $parent
        $parent = $null
        return $result
    }
    finally {
        Release-ComObject $parent
    }
}

function Convert-MinutesToIsoDuration {
    param([int]$Minutes)
    if ($Minutes -le 0) { return $null }
    return 'PT{0}M' -f $Minutes
}

function Register-TaskFromData {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [string]$OriginalFullPath
    )
    Connect-TaskService
    $folder = $null
    $definition = $null
    $registrationInfo = $null
    $principal = $null
    $settings = $null
    $triggers = $null
    $trigger = $null
    $repetition = $null
    $actions = $null
    $action = $null
    $registeredTask = $null
    $sourceFolder = $null
    $sourceTask = $null
    $sourceActionsForRuntime = $null
    $sourceActionForRuntime = $null
    $oldRuntimeInfo = $null
    $backgroundInstallState = $null
    $registrationSucceeded = $false
    try {
        $backgroundMode = $false
        if ($null -ne $Data.PSObject.Properties['BackgroundMode']) {
            $backgroundMode = [bool]$Data.BackgroundMode
        }
        $folder = Ensure-TaskFolder $Data.TaskPath
        if (-not [string]::IsNullOrWhiteSpace($OriginalFullPath)) {
            $sourceParts = Split-RegisteredTaskPath $OriginalFullPath
            $sourceFolder = $script:TaskService.GetFolder($sourceParts.Folder)
            $sourceTask = $sourceFolder.GetTask($sourceParts.Name)
            $definition = $sourceTask.Definition
            try {
                $sourceActionsForRuntime = $definition.Actions
                if ([int]$sourceActionsForRuntime.Count -eq 1) {
                    $sourceActionForRuntime = $sourceActionsForRuntime.Item(1)
                    $oldRuntimeInfo = Get-BackgroundRuntimeInfo -FullTaskPath $OriginalFullPath -Action $sourceActionForRuntime
                }
            }
            finally {
                Release-ComObject $sourceActionForRuntime
                $sourceActionForRuntime = $null
                Release-ComObject $sourceActionsForRuntime
                $sourceActionsForRuntime = $null
            }
        }
        else {
            $definition = $script:TaskService.NewTask(0)
        }
        $registrationInfo = $definition.RegistrationInfo
        $registrationInfo.Description = $Data.Description
        if ([string]::IsNullOrWhiteSpace([string]$registrationInfo.Author)) {
            $registrationInfo.Author = $script:CurrentUserName
        }

        $principal = $definition.Principal
        $principal.UserId = $script:CurrentSid
        $principal.LogonType = $script:TASK_LOGON_INTERACTIVE_TOKEN
        $principal.RunLevel = $script:TASK_RUNLEVEL_LUA

        $settings = $definition.Settings
        $settings.Enabled = [bool]$Data.Enabled
        $settings.AllowDemandStart = $true
        $settings.StartWhenAvailable = $true
        $settings.DisallowStartIfOnBatteries = $false
        $settings.StopIfGoingOnBatteries = $false
        $settings.ExecutionTimeLimit = if ($backgroundMode) { 'PT0S' } else { 'PT72H' }
        if ($backgroundMode) {
            # TASK_INSTANCES_IGNORE_NEW prevents duplicate long-running services.
            $settings.MultipleInstances = 2
        }
        elseif ($null -ne $oldRuntimeInfo) {
            $settings.MultipleInstances = 0
        }

        $triggers = $definition.Triggers
        $triggers.Clear()
        switch ($Data.TriggerKind) {
            '登录时' {
                $trigger = $triggers.Create($script:TASK_TRIGGER_LOGON)
                $trigger.UserId = $script:CurrentSid
            }
            '每天' {
                $trigger = $triggers.Create($script:TASK_TRIGGER_DAILY)
                $trigger.StartBoundary = $Data.StartDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
                $trigger.DaysInterval = 1
            }
            default {
                $trigger = $triggers.Create($script:TASK_TRIGGER_TIME)
                $trigger.StartBoundary = $Data.StartDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
            }
        }
        $trigger.Enabled = $true

        if ([int]$Data.RepeatMinutes -gt 0 -and $Data.TriggerKind -ne '登录时') {
            $repetition = $trigger.Repetition
            $repetition.Interval = Convert-MinutesToIsoDuration ([int]$Data.RepeatMinutes)
            $repetition.Duration = if ($Data.TriggerKind -eq '每天') { 'P1D' } else { 'P7D' }
            $repetition.StopAtDurationEnd = $false
        }

        $fullPath = Join-TaskFullPath $Data.TaskPath $Data.TaskName
        $effectiveProgram = [string]$Data.Program
        $effectiveArguments = [string]$Data.Arguments
        $effectiveWorkingDirectory = [string]$Data.WorkingDirectory
        if ($backgroundMode) {
            $backgroundInstallState = Install-BackgroundRuntime -Data $Data -FullTaskPath $fullPath -OriginalFullPath $OriginalFullPath
            $effectiveProgram = $backgroundInstallState.Values.WscriptPath
            $effectiveArguments = $backgroundInstallState.Values.ActionArguments
            $effectiveWorkingDirectory = $backgroundInstallState.Values.RuntimeDirectory
        }

        $actions = $definition.Actions
        $actions.Clear()
        $action = $actions.Create($script:TASK_ACTION_EXEC)
        $action.Path = $effectiveProgram
        $action.Arguments = $effectiveArguments
        $action.WorkingDirectory = $effectiveWorkingDirectory

        $flags = $script:TASK_CREATE
        if ($Data.Overwrite) {
            $flags = $script:TASK_CREATE -bor $script:TASK_UPDATE
        }
        $registeredTask = $folder.RegisterTaskDefinition(
            $Data.TaskName,
            $definition,
            $flags,
            $script:CurrentSid,
            $null,
            $script:TASK_LOGON_INTERACTIVE_TOKEN,
            $null
        )
        $registrationSucceeded = $true

        Write-AppLog -Message ('已注册任务 {0}；InteractiveToken；LeastPrivilege' -f $fullPath)

        if (-not [string]::IsNullOrWhiteSpace($OriginalFullPath) -and $OriginalFullPath -ne $fullPath) {
            # A rename/move is a create followed by removal; confirmation was obtained by the editor.
            $oldParts = Split-RegisteredTaskPath $OriginalFullPath
            $oldFolder = $null
            try {
                $oldFolder = $script:TaskService.GetFolder($oldParts.Folder)
                $oldFolder.DeleteTask($oldParts.Name, 0)
                Write-AppLog -Message ('编辑任务时已删除旧路径 {0}' -f $OriginalFullPath)
            }
            catch {
                $message = Get-FriendlyError -ErrorRecord $_ -Context ('删除编辑前的任务 {0}' -f $OriginalFullPath)
                throw ('新任务已保存为 {0}，但{1}' -f $fullPath, $message)
            }
            finally {
                Release-ComObject $oldFolder
            }
        }

        if ($null -ne $oldRuntimeInfo) {
            $newRuntimeDirectory = if ($backgroundMode) { [string]$backgroundInstallState.Values.RuntimeDirectory } else { $null }
            if (-not $backgroundMode -or
                -not [string]::Equals([string]$oldRuntimeInfo.RuntimeDirectory, $newRuntimeDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    Remove-BackgroundRuntimeFiles -RuntimeInfo $oldRuntimeInfo -DeleteLogs $false
                }
                catch {
                    Write-AppLog -Level WARN -Message ('旧后台运行脚本清理失败 {0}：{1}' -f $OriginalFullPath, $_.Exception.Message)
                }
            }
        }
        return $fullPath
    }
    catch {
        if (-not $registrationSucceeded -and $null -ne $backgroundInstallState) {
            Restore-BackgroundRuntimeState $backgroundInstallState
        }
        throw
    }
    finally {
        Release-ComObject $registeredTask
        Release-ComObject $action
        Release-ComObject $actions
        Release-ComObject $repetition
        Release-ComObject $trigger
        Release-ComObject $triggers
        Release-ComObject $settings
        Release-ComObject $principal
        Release-ComObject $registrationInfo
        Release-ComObject $definition
        Release-ComObject $sourceTask
        Release-ComObject $sourceFolder
        Release-ComObject $sourceActionForRuntime
        Release-ComObject $sourceActionsForRuntime
        Release-ComObject $folder
    }
}

function Test-TaskExists {
    param(
        [string]$FolderPath,
        [string]$TaskName
    )
    $folder = $null
    $task = $null
    try {
        Connect-TaskService
        $folder = $script:TaskService.GetFolder((Normalize-FolderPath $FolderPath))
        $task = $folder.GetTask($TaskName)
        return $true
    }
    catch {
        $unsigned = $_.Exception.HResult -band 0xFFFFFFFF
        if ($unsigned -eq 0x80070002 -or $unsigned -eq 0x8004130F) {
            return $false
        }
        # Missing folders are not existing tasks; folder creation will handle them.
        if ($_.Exception.Message -match 'cannot find|找不到|不存在') {
            return $false
        }
        throw
    }
    finally {
        Release-ComObject $task
        Release-ComObject $folder
    }
}

function Show-TaskEditor {
    param(
        [ValidateSet('Create', 'Edit')][string]$Mode,
        $ExistingData
    )

    [xml]$editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="任务" Width="760" Height="760" MinWidth="680" MinHeight="680"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="135"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Margin="0,0,0,12" TextWrapping="Wrap"
                   Text="任务始终使用当前用户、InteractiveToken 和 LeastPrivilege 注册；不保存密码。"/>
        <Label Grid.Row="1" Grid.Column="0" Content="TaskPath"/>
        <ComboBox x:Name="TaskPathBox" Grid.Row="1" Grid.Column="1" Margin="4" IsEditable="True"/>
        <Label Grid.Row="2" Grid.Column="0" Content="TaskName"/>
        <TextBox x:Name="TaskNameBox" Grid.Row="2" Grid.Column="1" Margin="4"/>
        <Label Grid.Row="3" Grid.Column="0" Content="描述"/>
        <TextBox x:Name="DescriptionBox" Grid.Row="3" Grid.Column="1" Margin="4" Height="70"
                 AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        <Label Grid.Row="4" Grid.Column="0" Content="状态"/>
        <CheckBox x:Name="EnabledBox" Grid.Row="4" Grid.Column="1" Margin="8,7" Content="启用任务" IsChecked="True"/>
        <Separator Grid.Row="5" Grid.ColumnSpan="2" Margin="0,10"/>
        <Label Grid.Row="6" Grid.Column="0" Content="程序路径"/>
        <Grid Grid.Row="6" Grid.Column="1">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox x:Name="ProgramBox" Margin="4"/>
          <Button x:Name="BrowseButton" Grid.Column="1" Width="75" Margin="4" Content="浏览..."/>
        </Grid>
        <Label Grid.Row="7" Grid.Column="0" Content="参数"/>
        <TextBox x:Name="ArgumentsBox" Grid.Row="7" Grid.Column="1" Margin="4"/>
        <Label Grid.Row="8" Grid.Column="0" Content="工作目录"/>
        <TextBox x:Name="WorkingDirectoryBox" Grid.Row="8" Grid.Column="1" Margin="4"/>
        <Label Grid.Row="9" Grid.Column="0" Content="运行方式"/>
        <CheckBox x:Name="BackgroundBox" Grid.Row="9" Grid.Column="1" Margin="8,7"
                  Content="后台应用（无控制台窗口，记录 stdout/stderr）"/>
        <TextBlock Grid.Row="10" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666" TextWrapping="Wrap"
                   Text="运行文件按完整任务路径的 SHA-256 隔离，位于 %LOCALAPPDATA%\UserTaskManager\Tasks\&lt;hash&gt;\。"/>
        <Label Grid.Row="11" Grid.Column="0" Content="日志目录（可选）"/>
        <Grid Grid.Row="11" Grid.Column="1">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox x:Name="LogDirectoryBox" Margin="4" ToolTip="仅用于后台应用；留空使用任务专属默认目录"
                   IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
          <Button x:Name="BrowseLogDirectoryButton" Grid.Column="1" Width="75" Margin="4" Content="浏览..."
                  IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
        </Grid>
        <TextBlock Grid.Row="12" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666" TextWrapping="Wrap"
                   Text="仅用于后台应用。留空时日志保存在上述任务专属目录的 logs 子目录。"/>
        <Separator Grid.Row="13" Grid.ColumnSpan="2" Margin="0,10"/>
        <Label Grid.Row="14" Grid.Column="0" Content="触发器"/>
        <ComboBox x:Name="TriggerKindBox" Grid.Row="14" Grid.Column="1" Margin="4" SelectedIndex="0">
          <ComboBoxItem Content="登录时"/><ComboBoxItem Content="单次"/><ComboBoxItem Content="每天"/>
        </ComboBox>
        <Label Grid.Row="15" Grid.Column="0" Content="开始日期和时间"/>
        <StackPanel Grid.Row="15" Grid.Column="1" Orientation="Horizontal">
          <DatePicker x:Name="StartDatePicker" Width="180" Margin="4"/>
          <TextBox x:Name="StartTimeBox" Width="90" Margin="4" ToolTip="HH:mm"/>
          <TextBlock Margin="4,7" Text="（登录触发器忽略此项）"/>
        </StackPanel>
        <Label Grid.Row="16" Grid.Column="0" Content="重复间隔（分钟）"/>
        <StackPanel Grid.Row="16" Grid.Column="1" Orientation="Horizontal">
          <TextBox x:Name="RepeatMinutesBox" Width="90" Margin="4" Text="0"/>
          <TextBlock Margin="4,7" Text="0 表示不重复；登录触发器不支持重复"/>
        </StackPanel>
      </Grid>
    </ScrollViewer>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button x:Name="SaveButton" Width="95" Margin="4" IsDefault="True" Content="保存"/>
      <Button x:Name="CancelButton" Width="95" Margin="4" IsCancel="True" Content="取消"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader $editorXaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Owner = $script:MainWindow
    $window.Title = if ($Mode -eq 'Create') { '创建任务' } else { '编辑任务' }

    $taskPathBox = $window.FindName('TaskPathBox')
    $taskNameBox = $window.FindName('TaskNameBox')
    $descriptionBox = $window.FindName('DescriptionBox')
    $enabledBox = $window.FindName('EnabledBox')
    $programBox = $window.FindName('ProgramBox')
    $argumentsBox = $window.FindName('ArgumentsBox')
    $workingDirectoryBox = $window.FindName('WorkingDirectoryBox')
    $backgroundBox = $window.FindName('BackgroundBox')
    $logDirectoryBox = $window.FindName('LogDirectoryBox')
    $triggerKindBox = $window.FindName('TriggerKindBox')
    $startDatePicker = $window.FindName('StartDatePicker')
    $startTimeBox = $window.FindName('StartTimeBox')
    $repeatMinutesBox = $window.FindName('RepeatMinutesBox')
    $browseButton = $window.FindName('BrowseButton')
    $browseLogDirectoryButton = $window.FindName('BrowseLogDirectoryButton')
    $saveButton = $window.FindName('SaveButton')
    $cancelButton = $window.FindName('CancelButton')

    foreach ($path in $script:FolderPaths) {
        [void]$taskPathBox.Items.Add($path)
    }

    if ($Mode -eq 'Edit') {
        $taskPathBox.Text = $ExistingData.TaskPath
        $taskNameBox.Text = $ExistingData.TaskName
        $descriptionBox.Text = $ExistingData.Description
        $enabledBox.IsChecked = $ExistingData.Enabled
        $programBox.Text = $ExistingData.Program
        $argumentsBox.Text = $ExistingData.Arguments
        $workingDirectoryBox.Text = $ExistingData.WorkingDirectory
        $backgroundBox.IsChecked = [bool]$ExistingData.BackgroundMode
        if ($null -ne $ExistingData.PSObject.Properties['LogDirectory']) {
            $logDirectoryBox.Text = [string]$ExistingData.LogDirectory
        }
        foreach ($item in $triggerKindBox.Items) {
            if ([string]$item.Content -eq $ExistingData.TriggerKind) {
                $triggerKindBox.SelectedItem = $item
                break
            }
        }
        $startDatePicker.SelectedDate = $ExistingData.StartDate
        $startTimeBox.Text = $ExistingData.StartTime
        $repeatMinutesBox.Text = [string]$ExistingData.RepeatMinutes
    }
    else {
        $taskPathBox.Text = $script:CurrentFolderPath
        $startDatePicker.SelectedDate = (Get-Date).Date.AddDays(1)
        $startTimeBox.Text = '09:00'
    }

    $browseButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Title = '选择要运行的程序'
        $dialog.Filter = '可执行文件 (*.exe;*.com;*.bat;*.cmd)|*.exe;*.com;*.bat;*.cmd|所有文件 (*.*)|*.*'
        if ($dialog.ShowDialog($window)) {
            $programBox.Text = $dialog.FileName
            if ([string]::IsNullOrWhiteSpace($workingDirectoryBox.Text)) {
                $workingDirectoryBox.Text = [IO.Path]::GetDirectoryName($dialog.FileName)
            }
        }
    })

    $cancelButton.Add_Click({ $window.DialogResult = $false })
    $saveButton.Add_Click({
        try {
            $taskNameError = Test-TaskName $taskNameBox.Text
            if ($null -ne $taskNameError) { throw $taskNameError }
            $pathError = Test-FolderPath $taskPathBox.Text
            if ($null -ne $pathError) { throw $pathError }
            if ([string]::IsNullOrWhiteSpace($programBox.Text)) {
                throw '程序路径不能为空。'
            }
            if ($programBox.Text.IndexOf([char]0) -ge 0 -or
                $argumentsBox.Text.IndexOf([char]0) -ge 0 -or
                $workingDirectoryBox.Text.IndexOf([char]0) -ge 0) {
                throw '程序、参数或工作目录包含无效字符。'
            }

            $kind = [string]$triggerKindBox.SelectedItem.Content
            $startDateTime = Get-Date
            if ($kind -ne '登录时') {
                if ($null -eq $startDatePicker.SelectedDate) {
                    throw '请选择开始日期。'
                }
                $parsedTime = [DateTime]::MinValue
                if (-not [DateTime]::TryParseExact(
                    $startTimeBox.Text.Trim(),
                    'HH:mm',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None,
                    [ref]$parsedTime
                )) {
                    throw '开始时间必须使用 24 小时 HH:mm 格式，例如 09:30。'
                }
                $startDateTime = $startDatePicker.SelectedDate.Value.Date.Add($parsedTime.TimeOfDay)
            }

            $repeatMinutes = 0
            if (-not [int]::TryParse($repeatMinutesBox.Text.Trim(), [ref]$repeatMinutes) -or
                $repeatMinutes -lt 0 -or $repeatMinutes -gt 44640) {
                throw '重复间隔必须是 0 到 44640 之间的整数分钟数。'
            }
            if ($kind -eq '登录时' -and $repeatMinutes -ne 0) {
                throw '登录触发器不支持重复间隔，请填写 0。'
            }
            if ($repeatMinutes -gt 0 -and $repeatMinutes -lt 1) {
                throw '重复间隔至少为 1 分钟。'
            }

            $normalizedPath = Normalize-FolderPath $taskPathBox.Text
            $name = $taskNameBox.Text
            $fullPath = Join-TaskFullPath $normalizedPath $name
            if ([bool]$backgroundBox.IsChecked) {
                $runtimeValues = Get-BackgroundActionValues $fullPath
                [void](Resolve-BackgroundLogDirectory -RequestedPath $logDirectoryBox.Text -DefaultPath $runtimeValues.DefaultLogDirectory)
            }
            $originalPath = if ($Mode -eq 'Edit') { [string]$ExistingData.FullPath } else { $null }
            $isSameTask = $Mode -eq 'Edit' -and $originalPath -eq $fullPath
            $exists = $false
            try {
                $exists = Test-TaskExists -FolderPath $normalizedPath -TaskName $name
            }
            catch {
                throw (Get-FriendlyError -ErrorRecord $_ -Context ('检查任务 {0}' -f $fullPath))
            }

            $overwrite = $false
            if ($exists) {
                $prompt = if ($isSameTask) {
                    "即将编辑现有任务：`n`n完整 TaskPath + TaskName：$fullPath`n`n确认以表单中的定义覆盖该任务吗？"
                }
                elseif ($Mode -eq 'Edit') {
                    "即将编辑并移动或重命名现有任务：`n$originalPath`n`n目标位置已有任务：`n$fullPath`n`n继续将覆盖目标任务，并在成功后删除原任务。确认吗？"
                }
                else {
                    "同名任务已经存在：`n`n完整 TaskPath + TaskName：$fullPath`n`n确认覆盖吗？"
                }
                $answer = [Windows.MessageBox]::Show(
                    $window,
                    $prompt,
                    '确认覆盖现有任务',
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning,
                    [Windows.MessageBoxResult]::No
                )
                if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
                $overwrite = $true
            }
            elseif ($Mode -eq 'Edit') {
                $prompt = "即将把现有任务：`n$originalPath`n`n保存为：`n$fullPath`n`n保存成功后将删除原任务。确认继续吗？"
                $answer = [Windows.MessageBox]::Show(
                    $window,
                    $prompt,
                    '确认移动或重命名任务',
                    [Windows.MessageBoxButton]::YesNo,
                    [Windows.MessageBoxImage]::Warning,
                    [Windows.MessageBoxResult]::No
                )
                if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
            }

            $window.Tag = [PSCustomObject]@{
                TaskPath = $normalizedPath
                TaskName = $name
                Description = [string]$descriptionBox.Text
                Enabled = [bool]$enabledBox.IsChecked
                Program = [string]$programBox.Text
                Arguments = [string]$argumentsBox.Text
                WorkingDirectory = [string]$workingDirectoryBox.Text
                BackgroundMode = [bool]$backgroundBox.IsChecked
                LogDirectory = [string]$logDirectoryBox.Text
                TriggerKind = $kind
                StartDateTime = $startDateTime
                RepeatMinutes = $repeatMinutes
                Overwrite = $overwrite
            }
            $window.DialogResult = $true
        }
        catch {
            [void][Windows.MessageBox]::Show(
                $window,
                $_.Exception.Message,
                '输入无效',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Warning
            )
        }
    })

    if ($window.ShowDialog()) {
        return $window.Tag
    }
    return $null
}

function Show-DeleteTaskDialog {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    [xml]$deleteXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="二次确认删除任务" Width="570" Height="285" ResizeMode="NoResize"
        WindowStartupLocation="CenterOwner">
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" FontWeight="SemiBold" FontSize="15" Text="即将删除现有任务："/>
    <TextBox x:Name="PathText" Grid.Row="1" Margin="0,10,0,10" IsReadOnly="True"
             TextWrapping="Wrap" BorderThickness="1" Padding="7"/>
    <TextBlock Grid.Row="2" Foreground="#A00000" TextWrapping="Wrap"
               Text="任务删除后无法由本程序恢复。若这是后台应用，wrapper.ps1、run.vbs 和 config.json 会一并删除。"/>
    <CheckBox x:Name="DeleteLogsBox" Grid.Row="3" Margin="0,14,0,0" VerticalAlignment="Top"
              Content="同时删除该后台任务生成的日志文件（自定义目录中的其他文件不会删除）"/>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="DeleteButton" Width="100" Margin="4" IsDefault="True" Content="确认删除"/>
      <Button x:Name="CancelButton" Width="100" Margin="4" IsCancel="True" Content="取消"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader $deleteXaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Owner = $script:MainWindow
    $window.FindName('PathText').Text = $FullTaskPath
    $deleteLogsBox = $window.FindName('DeleteLogsBox')
    $window.FindName('DeleteButton').Add_Click({
        $window.Tag = [bool]$deleteLogsBox.IsChecked
        $window.DialogResult = $true
    })

    $browseLogDirectoryButton.Add_Click({
        $dialog = New-Object Windows.Forms.FolderBrowserDialog
        $dialog.Description = '选择后台应用日志目录'
        $dialog.ShowNewFolderButton = $true
        try {
            $candidate = [Environment]::ExpandEnvironmentVariables($logDirectoryBox.Text.Trim())
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and [IO.Directory]::Exists($candidate)) {
                $dialog.SelectedPath = [IO.Path]::GetFullPath($candidate)
            }
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $logDirectoryBox.Text = $dialog.SelectedPath
            }
        }
        finally {
            $dialog.Dispose()
        }
    })
    $window.FindName('CancelButton').Add_Click({ $window.DialogResult = $false })
    if ($window.ShowDialog()) {
        return [PSCustomObject]@{ Confirmed = $true; DeleteLogs = [bool]$window.Tag }
    }
    return [PSCustomObject]@{ Confirmed = $false; DeleteLogs = $false }
}

[xml]$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UserTaskManager - 轻量级任务计划管理器"
        Width="1280" Height="780" MinWidth="980" MinHeight="620"
        WindowStartupLocation="CenterScreen">
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#F3F3F3" BorderBrush="#D0D0D0" BorderThickness="0,0,0,1">
      <ToolBarTray Background="Transparent">
        <ToolBar Background="Transparent">
          <Button x:Name="RefreshButton" Padding="12,5" Content="刷新"/>
          <Separator/>
          <Button x:Name="CreateButton" Padding="12,5" Content="创建任务"/>
          <Button x:Name="EditButton" Padding="12,5" Content="编辑任务"/>
          <Button x:Name="DeleteButton" Padding="12,5" Content="删除任务"/>
          <Separator/>
          <Button x:Name="RunButton" Padding="12,5" Content="立即运行"/>
          <Button x:Name="StopButton" Padding="12,5" Content="停止"/>
          <Button x:Name="EnableButton" Padding="12,5" Content="启用"/>
          <Button x:Name="DisableButton" Padding="12,5" Content="禁用"/>
          <Separator/>
          <Button x:Name="ViewXmlButton" Padding="12,5" Content="查看 XML"/>
          <Button x:Name="ExportXmlButton" Padding="12,5" Content="导出 XML"/>
          <Button x:Name="OpenLogButton" Padding="12,5" Content="打开任务日志"/>
        </ToolBar>
      </ToolBarTray>
    </Border>
    <StatusBar DockPanel.Dock="Bottom">
      <StatusBarItem>
        <TextBlock x:Name="StatusText" Text="准备就绪"/>
      </StatusBarItem>
      <Separator/>
      <StatusBarItem HorizontalAlignment="Right">
        <TextBlock x:Name="CountText" Text="当前任务数：0"/>
      </StatusBarItem>
    </StatusBar>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="250" MinWidth="170"/>
        <ColumnDefinition Width="5"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Grid.Column="0" BorderBrush="#D0D0D0" BorderThickness="0,0,1,0">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" FontWeight="SemiBold" Padding="10,8" Background="#F7F7F7"
                     Text="任务文件夹"/>
          <TreeView x:Name="FolderTree" Margin="5"/>
        </DockPanel>
      </Border>
      <GridSplitter Grid.Column="1" HorizontalAlignment="Stretch" Background="#E0E0E0"/>
      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="3*"/>
          <RowDefinition Height="5"/>
          <RowDefinition Height="2*"/>
        </Grid.RowDefinitions>
        <DataGrid x:Name="TaskGrid" Grid.Row="0" AutoGenerateColumns="False" IsReadOnly="True"
                  SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False"
                  HeadersVisibility="Column" GridLinesVisibility="Horizontal"
                  EnableRowVirtualization="True" EnableColumnVirtualization="True">
          <DataGrid.Columns>
            <DataGridTextColumn Header="任务名称" Binding="{Binding Name}" Width="180"/>
            <DataGridTextColumn Header="任务路径" Binding="{Binding Path}" Width="230"/>
            <DataGridTextColumn Header="状态" Binding="{Binding State}" Width="90"/>
            <DataGridCheckBoxColumn Header="启用" Binding="{Binding Enabled}" Width="60"/>
            <DataGridTextColumn Header="运行账户" Binding="{Binding RunAs}" Width="170"/>
            <DataGridTextColumn Header="上次运行时间" Binding="{Binding LastRun}" Width="150"/>
            <DataGridTextColumn Header="下次运行时间" Binding="{Binding NextRun}" Width="150"/>
            <DataGridTextColumn Header="上次运行结果" Binding="{Binding LastResult}" Width="150"/>
            <DataGridTextColumn Header="触发器摘要" Binding="{Binding Triggers}" Width="280"/>
            <DataGridTextColumn Header="操作摘要" Binding="{Binding Actions}" Width="320"/>
          </DataGrid.Columns>
        </DataGrid>
        <GridSplitter Grid.Row="1" VerticalAlignment="Stretch" HorizontalAlignment="Stretch" Background="#E0E0E0"/>
        <DockPanel Grid.Row="2">
          <TextBlock DockPanel.Dock="Top" FontWeight="SemiBold" Padding="10,8" Background="#F7F7F7"
                     Text="任务详情"/>
          <TextBox x:Name="DetailText" Margin="8" IsReadOnly="True" AcceptsReturn="True"
                   TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                   FontFamily="Segoe UI" Text="请选择一个任务。"/>
        </DockPanel>
      </Grid>
    </Grid>
  </DockPanel>
</Window>
'@

$mainReader = New-Object Xml.XmlNodeReader $mainXaml
$script:MainWindow = [Windows.Markup.XamlReader]::Load($mainReader)
$script:FolderTree = $script:MainWindow.FindName('FolderTree')
$script:TaskGrid = $script:MainWindow.FindName('TaskGrid')
$script:DetailText = $script:MainWindow.FindName('DetailText')
$script:StatusText = $script:MainWindow.FindName('StatusText')
$script:CountText = $script:MainWindow.FindName('CountText')
$script:RefreshButton = $script:MainWindow.FindName('RefreshButton')
$script:ActionPanel = $script:MainWindow.FindName('CreateButton').Parent

$script:RefreshButton.Add_Click({ Refresh-All })
$script:TaskGrid.Add_SelectionChanged({ Update-TaskDetails })
$script:FolderTree.Add_SelectedItemChanged({
    if (-not $script:IsBusy -and $null -ne $script:FolderTree.SelectedItem) {
        Refresh-TaskList -FolderPath ([string]$script:FolderTree.SelectedItem.Tag)
    }
})

$script:MainWindow.FindName('RunButton').Add_Click({
    Invoke-WithSelectedTask -OperationName '立即运行' -Operation {
        param($folder, $task, $model)
        $running = $task.Run($null)
        Release-ComObject $running
    }
})
$script:MainWindow.FindName('StopButton').Add_Click({
    Invoke-WithSelectedTask -OperationName '停止' -Operation {
        param($folder, $task, $model)
        $task.Stop(0)
    }
})
$script:MainWindow.FindName('EnableButton').Add_Click({
    Invoke-WithSelectedTask -OperationName '启用' -Operation {
        param($folder, $task, $model)
        $task.Enabled = $true
    }
})
$script:MainWindow.FindName('DisableButton').Add_Click({
    Invoke-WithSelectedTask -OperationName '禁用' -Operation {
        param($folder, $task, $model)
        $task.Enabled = $false
    }
})

$script:MainWindow.FindName('DeleteButton').Add_Click({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }
    $deleteOptions = Show-DeleteTaskDialog -FullTaskPath $selected.Path
    if (-not $deleteOptions.Confirmed) { return }
    Invoke-WithSelectedTask -OperationName '删除' -Operation {
        param($folder, $task, $model)
        $definition = $null
        $actions = $null
        $taskAction = $null
        $runtimeInfo = $null
        try {
            $definition = $task.Definition
            $actions = $definition.Actions
            if ([int]$actions.Count -eq 1) {
                $taskAction = $actions.Item(1)
                $runtimeInfo = Get-BackgroundRuntimeInfo -FullTaskPath $model.Path -Action $taskAction
            }
        }
        finally {
            Release-ComObject $taskAction
            Release-ComObject $actions
            Release-ComObject $definition
        }
        $parts = Split-RegisteredTaskPath $model.Path
        $folder.DeleteTask($parts.Name, 0)
        if ($null -ne $runtimeInfo) {
            try {
                Remove-BackgroundRuntimeFiles -RuntimeInfo $runtimeInfo -DeleteLogs ([bool]$deleteOptions.DeleteLogs)
            }
            catch {
                $cleanupMessage = '任务已删除，但后台运行文件清理失败：{0}' -f $_.Exception.Message
                Write-AppLog -Level WARN -Message $cleanupMessage
                Show-InfoMessage $cleanupMessage
            }
        }
    }
})

$script:MainWindow.FindName('ViewXmlButton').Add_Click({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }
    try {
        $xml = Get-RegisteredTaskXml $selected.Path
        Show-XmlWindow -TaskPath $selected.Path -Xml $xml
        Set-Status -Text ('已读取 XML：{0}' -f $selected.Path)
    }
    catch {
        Show-ErrorMessage (Get-FriendlyError -ErrorRecord $_ -Context ('查看 XML {0}' -f $selected.Path))
    }
})

$script:MainWindow.FindName('OpenLogButton').Add_Click({
    if ($script:IsBusy) { return }
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个后台应用任务。'
        return
    }
    Set-Busy -Busy $true -Status ('正在读取日志目录：{0}' -f $selected.Path)
    try {
        $runtimeInfo = Get-RegisteredTaskBackgroundInfo -FullPath $selected.Path
        if ($null -eq $runtimeInfo) {
            throw '所选任务不是由本程序配置的后台应用，或其后台配置文件缺失，无法确定日志目录。'
        }
        Open-DirectoryInExplorer -Path $runtimeInfo.LogDirectory
        $message = '已打开任务日志目录：{0}' -f $runtimeInfo.LogDirectory
        Write-AppLog -Message $message
        Set-Status -Text $message
    }
    catch {
        $message = Get-FriendlyError -ErrorRecord $_ -Context ('打开任务日志 {0}' -f $selected.Path)
        Show-ErrorMessage $message
        Set-Status -Text $message
    }
    finally {
        Set-Busy -Busy $false
    }
})

$script:MainWindow.FindName('ExportXmlButton').Add_Click({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = '导出任务 XML'
        $safeName = ($selected.Name -replace '[\\/:*?"<>|]', '_')
        $dialog.FileName = $safeName + '.xml'
        $dialog.Filter = 'XML 文件 (*.xml)|*.xml|所有文件 (*.*)|*.*'
        if ($dialog.ShowDialog($script:MainWindow)) {
            $xml = Get-RegisteredTaskXml $selected.Path
            # Task Scheduler returns an XML Unicode string whose declaration is UTF-16.
            [IO.File]::WriteAllText($dialog.FileName, $xml, [Text.Encoding]::Unicode)
            $message = '已导出 XML：{0}' -f $dialog.FileName
            Write-AppLog -Message $message
            Set-Status -Text $message
        }
    }
    catch {
        Show-ErrorMessage (Get-FriendlyError -ErrorRecord $_ -Context ('导出 XML {0}' -f $selected.Path))
    }
})

$script:MainWindow.FindName('CreateButton').Add_Click({
    $data = Show-TaskEditor -Mode Create
    if ($null -eq $data) { return }
    Set-Busy -Busy $true -Status '正在创建任务...'
    try {
        $fullPath = Register-TaskFromData -Data $data
        Show-InfoMessage ('任务创建成功：{0}' -f $fullPath)
        $script:CurrentFolderPath = $data.TaskPath
        Set-Status -Text ('任务创建成功：{0}' -f $fullPath)
    }
    catch {
        $message = if ($_.Exception.Message -match '失败：|新任务已保存') {
            $_.Exception.Message
        }
        else {
            Get-FriendlyError -ErrorRecord $_ -Context '创建任务'
        }
        Show-ErrorMessage $message
    }
    finally {
        Set-Busy -Busy $false
        Refresh-All
    }
})

$script:MainWindow.FindName('EditButton').Add_Click({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }
    try {
        $existing = Get-TaskEditData -FullPath $selected.Path
        if (-not $existing.Supported) {
            Show-InfoMessage ($existing.Reason + "`n`n为避免丢失原始配置，此任务保持只读。仍可查看或导出 XML。")
            return
        }
        $data = Show-TaskEditor -Mode Edit -ExistingData $existing
        if ($null -eq $data) { return }
        Set-Busy -Busy $true -Status ('正在编辑 {0} ...' -f $selected.Path)
        $newPath = Register-TaskFromData -Data $data -OriginalFullPath $selected.Path
        Show-InfoMessage ('任务编辑成功：{0}' -f $newPath)
        $script:CurrentFolderPath = $data.TaskPath
        Set-Status -Text ('任务编辑成功：{0}' -f $newPath)
    }
    catch {
        $message = if ($_.Exception.Message -match '失败：|新任务已保存') {
            $_.Exception.Message
        }
        else {
            Get-FriendlyError -ErrorRecord $_ -Context ('编辑任务 {0}' -f $selected.Path)
        }
        Show-ErrorMessage $message
    }
    finally {
        Set-Busy -Busy $false
        Refresh-All
    }
})

$script:MainWindow.Add_ContentRendered({
    Refresh-All
})
$script:MainWindow.Add_Closed({
    Write-AppLog -Message '应用已关闭。'
    Release-ComObject $script:TaskService
    $script:TaskService = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
})

Write-AppLog -Message ('应用启动；PowerShell={0}；ApartmentState={1}' -f $PSVersionTable.PSVersion, [Threading.Thread]::CurrentThread.ApartmentState)
if ($SmokeTest) {
    try {
        Connect-TaskService
        $smokeErrors = @(Refresh-FolderTree)
        $smokeModels = @(Get-FolderTaskModels -FolderPath '\')
        Write-Output ('SMOKE OK: STA={0}; Folders={1}; RootTasks={2}; SkippedFolders={3}' -f
            [Threading.Thread]::CurrentThread.ApartmentState,
            $script:FolderPaths.Count,
            $smokeModels.Count,
            $smokeErrors.Count)
    }
    finally {
        Release-ComObject $script:TaskService
        $script:TaskService = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    return
}
[void]$script:MainWindow.ShowDialog()
