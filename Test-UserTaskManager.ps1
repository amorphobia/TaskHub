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
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
