#requires -version 5.1
<#
    Safe integration tests for UserTaskManager.
    Only uniquely named tasks created by this process are touched, and all are
    deleted in finally. Existing tasks and folders are never modified.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Restart-InStaIfNeeded {
    if ([Threading.Thread]::CurrentThread.ApartmentState -eq [Threading.ApartmentState]::STA) {
        return $false
    }
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = '-NoProfile -STA -File "{0}"' -f $PSCommandPath.Replace('"', '\"')
    $info.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    exit $process.ExitCode
}

if (Restart-InStaIfNeeded) {
    return
}

$TASK_CREATE = 2
$TASK_LOGON_INTERACTIVE_TOKEN = 3
$TASK_RUNLEVEL_LUA = 0
$TASK_TRIGGER_TIME = 1
$TASK_TRIGGER_DAILY = 2
$TASK_TRIGGER_LOGON = 9
$TASK_ACTION_EXEC = 0

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $identity.User.Value
$uniquePrefix = 'UTM.Test.{0}' -f ([Guid]::NewGuid().ToString('N'))
$createdNames = New-Object 'System.Collections.Generic.List[string]'
$results = New-Object 'System.Collections.Generic.List[string]'
$service = $null
$root = $null
$backgroundCustomLogDirectory = $null

function Release-ComObject {
    param([object]$Value)
    if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value) } catch {}
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw ('断言失败：{0}' -f $Message)
    }
    $script:results.Add(('通过：{0}' -f $Message))
}

function Get-DescendantProcessRows {
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    $allProcesses = @(Get-CimInstance Win32_Process)
    $pendingParents = New-Object 'System.Collections.Generic.Queue[int]'
    $seen = @{}
    $results = New-Object 'System.Collections.Generic.List[object]'
    $pendingParents.Enqueue($RootProcessId)
    $seen[$RootProcessId] = $true
    while ($pendingParents.Count -gt 0) {
        $parentId = $pendingParents.Dequeue()
        foreach ($process in $allProcesses) {
            $processId = [int]$process.ProcessId
            if ([int]$process.ParentProcessId -eq $parentId -and -not $seen.ContainsKey($processId)) {
                $seen[$processId] = $true
                $pendingParents.Enqueue($processId)
                $results.Add([PSCustomObject]@{
                    ProcessId = $processId
                    ParentProcessId = [int]$process.ParentProcessId
                    Name = [string]$process.Name
                    CommandLine = [string]$process.CommandLine
                })
            }
        }
    }
    return $results
}

function Read-SharedLogText {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    $reader = $null
    try {
        $stream = New-Object IO.FileStream(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::Default, $true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-TestDefinition {
    param(
        [ValidateSet('Logon', 'Once', 'Daily')]
        [string]$Kind,
        [string]$Description
    )
    $definition = $null
    $registrationInfo = $null
    $principal = $null
    $settings = $null
    $triggers = $null
    $trigger = $null
    $actions = $null
    $action = $null
    try {
        $definition = $script:service.NewTask(0)
        $registrationInfo = $definition.RegistrationInfo
        $registrationInfo.Author = $identity.Name
        $registrationInfo.Description = $Description

        $principal = $definition.Principal
        $principal.UserId = $currentSid
        $principal.LogonType = $TASK_LOGON_INTERACTIVE_TOKEN
        $principal.RunLevel = $TASK_RUNLEVEL_LUA

        $settings = $definition.Settings
        $settings.Enabled = $true
        $settings.AllowDemandStart = $true
        $settings.StartWhenAvailable = $true
        $settings.DisallowStartIfOnBatteries = $false
        $settings.StopIfGoingOnBatteries = $false

        $triggers = $definition.Triggers
        switch ($Kind) {
            'Logon' {
                $trigger = $triggers.Create($TASK_TRIGGER_LOGON)
                $trigger.UserId = $currentSid
            }
            'Daily' {
                $trigger = $triggers.Create($TASK_TRIGGER_DAILY)
                $trigger.StartBoundary = (Get-Date).Date.AddDays(1).AddHours(9).ToString('yyyy-MM-ddTHH:mm:ss')
                $trigger.DaysInterval = 1
            }
            'Once' {
                $trigger = $triggers.Create($TASK_TRIGGER_TIME)
                $trigger.StartBoundary = (Get-Date).AddHours(1).ToString('yyyy-MM-ddTHH:mm:ss')
            }
        }
        $trigger.Enabled = $true

        $actions = $definition.Actions
        $action = $actions.Create($TASK_ACTION_EXEC)
        $action.Path = Join-Path $env:SystemRoot 'System32\PING.EXE'
        $action.Arguments = '127.0.0.1 -n 6'
        $action.WorkingDirectory = [Environment]::GetFolderPath('LocalApplicationData')

        return $definition
    }
    finally {
        Release-ComObject $action
        Release-ComObject $actions
        Release-ComObject $trigger
        Release-ComObject $triggers
        Release-ComObject $settings
        Release-ComObject $principal
        Release-ComObject $registrationInfo
        # The returned definition remains valid; the caller releases it.
    }
}

function Register-TestTask {
    param(
        [string]$Name,
        [ValidateSet('Logon', 'Once', 'Daily')][string]$Kind
    )
    $definition = $null
    $task = $null
    try {
        $definition = New-TestDefinition -Kind $Kind -Description ('UserTaskManager 安全测试；唯一名称={0}' -f $Name)
        $task = $script:root.RegisterTaskDefinition(
            $Name,
            $definition,
            $TASK_CREATE,
            $currentSid,
            $null,
            $TASK_LOGON_INTERACTIVE_TOKEN,
            $null
        )
        $script:createdNames.Add($Name)
        Assert-True ($task.Path -eq ('\' + $Name)) ('创建唯一测试任务 {0}' -f $Name)
    }
    finally {
        Release-ComObject $task
        Release-ComObject $definition
    }
}

function Verify-TestTask {
    param(
        [string]$Name,
        [int]$ExpectedTriggerType
    )
    $task = $null
    $definition = $null
    $principal = $null
    $triggers = $null
    $trigger = $null
    $actions = $null
    $action = $null
    try {
        $task = $script:root.GetTask($Name)
        $definition = $task.Definition
        $principal = $definition.Principal
        $triggers = $definition.Triggers
        $trigger = $triggers.Item(1)
        $actions = $definition.Actions
        $action = $actions.Item(1)

        Assert-True ([int]$principal.LogonType -eq $TASK_LOGON_INTERACTIVE_TOKEN) ('{0} 使用 InteractiveToken' -f $Name)
        Assert-True ([int]$principal.RunLevel -eq $TASK_RUNLEVEL_LUA) ('{0} 使用 LeastPrivilege' -f $Name)
        Assert-True ([int]$trigger.Type -eq $ExpectedTriggerType) ('{0} 触发器类型正确' -f $Name)
        Assert-True ([int]$actions.Count -eq 1 -and [int]$action.Type -eq $TASK_ACTION_EXEC) ('{0} 只有一个 Exec 操作' -f $Name)
        Assert-True ([string]$action.Arguments -eq '127.0.0.1 -n 6') ('{0} 参数按独立字段原样保存' -f $Name)
        Assert-True ([string]$action.WorkingDirectory -eq [Environment]::GetFolderPath('LocalApplicationData')) ('{0} 工作目录按独立字段保存' -f $Name)
    }
    finally {
        Release-ComObject $action
        Release-ComObject $actions
        Release-ComObject $trigger
        Release-ComObject $triggers
        Release-ComObject $principal
        Release-ComObject $definition
        Release-ComObject $task
    }
}

try {
    Write-Host ('测试用户：{0} ({1})' -f $identity.Name, $currentSid)
    Write-Host ('唯一测试前缀：{0}' -f $uniquePrefix)

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    Assert-True ([bool]$service.Connected) 'Task Scheduler COM 服务连接成功'

    $logonName = $uniquePrefix + '.登录'
    $onceName = $uniquePrefix + '.单次'
    $dailyName = $uniquePrefix + '.每日'

    Register-TestTask -Name $logonName -Kind Logon
    Register-TestTask -Name $onceName -Kind Once
    Register-TestTask -Name $dailyName -Kind Daily

    Verify-TestTask -Name $logonName -ExpectedTriggerType $TASK_TRIGGER_LOGON
    Verify-TestTask -Name $onceName -ExpectedTriggerType $TASK_TRIGGER_TIME
    Verify-TestTask -Name $dailyName -ExpectedTriggerType $TASK_TRIGGER_DAILY

    $controlTask = $null
    $running = $null
    try {
        $controlTask = $root.GetTask($onceName)
        $controlTask.Enabled = $false
        Assert-True (-not [bool]$controlTask.Enabled) '唯一测试任务可以禁用'
        $controlTask.Enabled = $true
        Assert-True ([bool]$controlTask.Enabled) '唯一测试任务可以启用'
        $running = $controlTask.Run($null)
        Start-Sleep -Milliseconds 400
        Assert-True ($null -ne $running) '唯一测试任务可以立即运行'
        $controlTask.Stop(0)
        Assert-True $true '唯一测试任务可以停止'
    }
    finally {
        Release-ComObject $running
        Release-ComObject $controlTask
    }

    # Exercise the actual embedded background runner and registration functions
    # from UserTaskManager.ps1. Only one additional GUID-named task is touched.
    $backgroundName = $uniquePrefix + '.后台'
    $backgroundFullPath = '\' + $backgroundName
    $backgroundFolder = $null
    $backgroundTask = $null
    $backgroundRunning = $null
    $backgroundRuntime = $null
    $backgroundRegistered = $false
    $backgroundProcessIds = @()
    $backgroundCustomLogDirectory = Join-Path $env:LOCALAPPDATA ('UserTaskManager\TestLogs\{0}' -f ([Guid]::NewGuid().ToString('N')))
    $backgroundLogSentinel = Join-Path $backgroundCustomLogDirectory 'unrelated.keep'
    try {
        $mainScriptPath = Join-Path $PSScriptRoot 'UserTaskManager.ps1'
        . $mainScriptPath -SmokeTest | ForEach-Object { Write-Host $_ }

        $sourceTokens = $null
        $sourceErrors = $null
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile(
            $mainScriptPath,
            [ref]$sourceTokens,
            [ref]$sourceErrors
        )
        Assert-True ($sourceErrors.Count -eq 0) '主应用通过 PowerShell 语法解析'
        $functionAsts = @($sourceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        $deleteDialogAst = $functionAsts | Where-Object Name -eq 'Show-DeleteTaskDialog' | Select-Object -First 1
        $taskEditorAst = $functionAsts | Where-Object Name -eq 'Show-TaskEditor' | Select-Object -First 1
        Assert-True ($null -ne $deleteDialogAst -and
            $deleteDialogAst.Extent.Text -notmatch 'browseLogDirectoryButton|logDirectoryBox') '删除确认窗口不引用任务编辑器的日志控件'
        Assert-True ($null -ne $taskEditorAst -and
            $taskEditorAst.Extent.Text -match 'browseLogDirectoryButton\.Add_Click') '日志目录浏览事件绑定在任务编辑器中'

        $sameLeafA = Get-BackgroundRuntimeDirectory ('\FolderA\' + $backgroundName)
        $sameLeafB = Get-BackgroundRuntimeDirectory ('\FolderB\' + $backgroundName)
        Assert-True (-not [string]::Equals($sameLeafA, $sameLeafB, [StringComparison]::OrdinalIgnoreCase)) '不同文件夹中的同名任务使用不同后台运行目录'
        Assert-True ([IO.Path]::GetFileName($sameLeafA) -match '^[0-9a-f]{64}$') '后台运行目录使用完整任务路径的 SHA-256 标识'
        $defaultValues = Get-BackgroundActionValues $backgroundFullPath
        $defaultLog = Resolve-BackgroundLogDirectory -RequestedPath '' -DefaultPath $defaultValues.DefaultLogDirectory
        Assert-True ($defaultLog.IsDefault -and [string]::Equals($defaultLog.Path, [IO.Path]::GetFullPath($defaultValues.DefaultLogDirectory), [StringComparison]::OrdinalIgnoreCase)) '留空日志路径会解析到任务专属默认 logs 目录'
        $legacyActionValues = New-BackgroundActionValues -RuntimeDirectory $defaultValues.RuntimeDirectory -Scheme 'HashedV2'
        $legacyAction = [PSCustomObject]@{
            Path = $legacyActionValues.ActionPath
            Arguments = $legacyActionValues.ActionArguments
        }
        Assert-True (Test-ActionTargetsBackgroundRunner -FullTaskPath $backgroundFullPath -Action $legacyAction) '仍可识别 Version 2 的 wscript + run.vbs action'

        $backgroundData = [PSCustomObject]@{
            TaskPath = '\'
            TaskName = $backgroundName
            Description = 'UserTaskManager 后台应用安全测试'
            Enabled = $true
            Program = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Arguments = '-NoLogo -NoProfile -NonInteractive -Command "Write-Output ''user-task-manager-background-ok''; $child = [Diagnostics.Process]::Start(($env:SystemRoot + ''\System32\PING.EXE''), ''127.0.0.1 -t''); $child.WaitForExit()"'
            WorkingDirectory = [Environment]::GetFolderPath('LocalApplicationData')
            BackgroundMode = $true
            LogDirectory = $backgroundCustomLogDirectory
            TriggerKind = '单次'
            StartDateTime = (Get-Date).AddHours(1)
            RepeatMinutes = 0
            Overwrite = $false
        }
        [void](Register-TaskFromData -Data $backgroundData)
        $backgroundRegistered = $true

        $editData = Get-TaskEditData -FullPath $backgroundFullPath
        Assert-True ($editData.Supported -and $editData.BackgroundMode) '后台测试任务可由编辑器无损识别'
        Assert-True ($editData.Program -eq $backgroundData.Program) '后台测试任务保留真实 executable 字段'
        Assert-True ([string]::Equals($editData.LogDirectory, [IO.Path]::GetFullPath($backgroundCustomLogDirectory), [StringComparison]::OrdinalIgnoreCase)) '编辑器回显自定义日志目录'

        Connect-TaskService
        $backgroundFolder = $script:TaskService.GetFolder('\')
        $backgroundTask = $backgroundFolder.GetTask($backgroundName)
        $backgroundDefinition = $null
        $backgroundActions = $null
        $backgroundAction = $null
        $backgroundSettings = $null
        try {
            $backgroundDefinition = $backgroundTask.Definition
            $backgroundActions = $backgroundDefinition.Actions
            $backgroundAction = $backgroundActions.Item(1)
            $backgroundSettings = $backgroundDefinition.Settings
            $backgroundRuntime = Get-BackgroundRuntimeInfo -FullTaskPath $backgroundFullPath -Action $backgroundAction
            $expectedWrapperPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Assert-True ($null -ne $backgroundRuntime -and $backgroundRuntime.Scheme -eq 'DirectPowerShellV3') '后台测试任务使用直接 PowerShell Version 3 包装器'
            Assert-True ([string]::Equals([string]$backgroundAction.Path, $expectedWrapperPowerShell, [StringComparison]::OrdinalIgnoreCase)) 'Task Scheduler 直接跟踪系统 Windows PowerShell'
            Assert-True ([string]$backgroundAction.Arguments -match '^-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File ') '包装器 action 使用隐藏且非交互的 PowerShell 参数'
            Assert-True ([string]::Equals([string]$backgroundAction.WorkingDirectory, $backgroundRuntime.RuntimeDirectory, [StringComparison]::OrdinalIgnoreCase)) '包装器 action 使用任务专属运行目录'
            Assert-True ([int]$backgroundRuntime.Config.Version -eq 3) '后台配置版本为 3'
            Assert-True (-not [IO.File]::Exists($backgroundRuntime.RunVbsPath)) '后台任务不部署 run.vbs'
            Assert-True (-not [bool]$backgroundRuntime.LogDirectoryIsDefault) '后台测试任务识别为自定义日志目录'
            Assert-True ([string]::Equals($backgroundRuntime.LogDirectory, [IO.Path]::GetFullPath($backgroundCustomLogDirectory), [StringComparison]::OrdinalIgnoreCase)) '后台任务日志写入规范化的自定义目录'
            Assert-True ([string]$backgroundSettings.ExecutionTimeLimit -eq 'PT0S') '后台测试任务没有 72 小时执行上限'
            Assert-True ([int]$backgroundSettings.MultipleInstances -eq 2) '后台测试任务使用 IgnoreNew 多实例策略'
        }
        finally {
            Release-ComObject $backgroundSettings
            Release-ComObject $backgroundAction
            Release-ComObject $backgroundActions
            Release-ComObject $backgroundDefinition
        }

        $backgroundRunning = $backgroundTask.Run($null)
        $deadline = (Get-Date).AddSeconds(15)
        $capturedOutput = ''
        do {
            Start-Sleep -Milliseconds 250
            if ([IO.File]::Exists($backgroundRuntime.StdOutPath)) {
                $capturedOutput = Read-SharedLogText $backgroundRuntime.StdOutPath
            }
        } while ($capturedOutput -notmatch 'user-task-manager-background-ok' -and (Get-Date) -lt $deadline)
        Assert-True ($capturedOutput -match 'user-task-manager-background-ok') '后台测试任务写入 stdout.log'
        [IO.File]::WriteAllText($backgroundLogSentinel, 'must-not-delete', [Text.Encoding]::UTF8)

        $wrapperEngineProcessId = [int]$backgroundRunning.EnginePID
        $descendants = @()
        do {
            Start-Sleep -Milliseconds 250
            $descendants = @(Get-DescendantProcessRows -RootProcessId $wrapperEngineProcessId)
        } while (($descendants.Count -lt 2 -or @($descendants | Where-Object Name -eq 'PING.EXE').Count -eq 0) -and
            (Get-Date) -lt $deadline)
        Assert-True ($descendants.Count -ge 2) '后台包装器启动目标进程及其子进程'
        Assert-True (@($descendants | Where-Object Name -eq 'PING.EXE').Count -eq 1) '后台测试进程树包含长时间运行的孙进程'
        $wrapperProcess = Get-Process -Id $wrapperEngineProcessId -ErrorAction Stop
        Assert-True ([IntPtr]$wrapperProcess.MainWindowHandle -eq [IntPtr]::Zero) 'Task Scheduler 直接启动的 PowerShell 包装器没有可见主窗口'
        $backgroundProcessIds = @($wrapperEngineProcessId) + @($descendants | ForEach-Object { [int]$_.ProcessId })

        $backgroundTask.Stop(0)
        $stopDeadline = (Get-Date).AddSeconds(15)
        $remainingProcesses = @()
        do {
            Start-Sleep -Milliseconds 250
            $remainingProcesses = @(Get-CimInstance Win32_Process | Where-Object {
                $backgroundProcessIds -contains [int]$_.ProcessId
            })
        } while ($remainingProcesses.Count -gt 0 -and (Get-Date) -lt $stopDeadline)
        Assert-True ($remainingProcesses.Count -eq 0) '停止任务会通过 Job Object 终止包装器、目标进程和孙进程'
        Assert-True ([int]$backgroundTask.State -ne 4) '停止后 Task Scheduler 不再报告运行实例'
    }
    finally {
        if ($null -ne $backgroundTask) {
            try {
                if ([int]$backgroundTask.State -eq 4) {
                    $backgroundTask.Stop(0)
                    Start-Sleep -Milliseconds 500
                }
            }
            catch {}
        }
        foreach ($processId in @($backgroundProcessIds)) {
            try {
                Stop-Process -Id $processId -Force -ErrorAction Stop
            }
            catch {
                if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
                    Write-Warning ('清理后台测试进程失败：PID {0}；{1}' -f $processId, $_.Exception.Message)
                }
            }
        }
        Release-ComObject $backgroundRunning
        Release-ComObject $backgroundTask
        if ($backgroundRegistered -and $null -ne $backgroundFolder) {
            try {
                $backgroundFolder.DeleteTask($backgroundName, 0)
                Write-Host ('已清理后台测试任务：{0}' -f $backgroundFullPath)
            }
            catch {
                Write-Warning ('清理后台测试任务失败：{0}；{1}' -f $backgroundFullPath, $_.Exception.Message)
            }
        }
        Release-ComObject $backgroundFolder
        if ($null -ne $backgroundRuntime) {
            try {
                Remove-BackgroundRuntimeFiles -RuntimeInfo $backgroundRuntime -DeleteLogs $true
                Write-Host ('已清理后台测试文件：{0}' -f $backgroundRuntime.RuntimeDirectory)
            }
            catch {
                Write-Warning ('清理后台测试文件失败：{0}' -f $_.Exception.Message)
            }
        }
        Release-ComObject $script:TaskService
        $script:TaskService = $null
    }

    Assert-True ([IO.File]::Exists($backgroundLogSentinel)) '清理自定义日志时保留目录中的非任务文件'
    [IO.File]::Delete($backgroundLogSentinel)
    if ([IO.Directory]::Exists($backgroundCustomLogDirectory) -and
        [IO.Directory]::GetFileSystemEntries($backgroundCustomLogDirectory).Count -eq 0) {
        [IO.Directory]::Delete($backgroundCustomLogDirectory, $false)
    }

    Write-Host ''
    Write-Host '全部测试通过：' -ForegroundColor Green
    $results | ForEach-Object { Write-Host ('  {0}' -f $_) }
}
catch {
    $unsigned = $_.Exception.HResult -band 0xFFFFFFFF
    if ($unsigned -eq 0x80070005 -or $_.Exception.Message -match 'Access.*denied|拒绝访问') {
        Write-Error 'Access denied（拒绝访问）：当前用户不能在根目录创建安全测试任务；未请求提升。'
    }
    else {
        Write-Error $_
    }
    exit 1
}
finally {
    if ($null -ne $root) {
        foreach ($name in @($createdNames)) {
            try {
                $root.DeleteTask($name, 0)
                Write-Host ('已清理测试任务：\{0}' -f $name)
            }
            catch {
                Write-Warning ('清理测试任务失败：\{0}；{1}' -f $name, $_.Exception.Message)
            }
        }
    }
    Release-ComObject $root
    Release-ComObject $service
    if (-not [string]::IsNullOrWhiteSpace($backgroundCustomLogDirectory)) {
        try {
            $testLogRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'UserTaskManager\TestLogs'))
            $testLogPath = [IO.Path]::GetFullPath($backgroundCustomLogDirectory)
            $requiredPrefix = $testLogRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if ($testLogPath.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Directory]::Exists($testLogPath)) {
                [IO.Directory]::Delete($testLogPath, $true)
            }
            if ([IO.Directory]::Exists($testLogRoot) -and
                [IO.Directory]::GetFileSystemEntries($testLogRoot).Count -eq 0) {
                [IO.Directory]::Delete($testLogRoot, $false)
            }
        }
        catch {
            Write-Warning ('清理唯一测试日志目录失败：{0}；{1}' -f $backgroundCustomLogDirectory, $_.Exception.Message)
        }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
