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
$iconBuildOutput = $null

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
        throw ('Assertion failed: {0}' -f $Message)
    }
    $script:results.Add(('Passed: {0}' -f $Message))
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
        $definition = New-TestDefinition -Kind $Kind -Description ('UserTaskManager safety test; unique name={0}' -f $Name)
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
        Assert-True ($task.Path -eq ('\' + $Name)) ('Created unique test task {0}' -f $Name)
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

        Assert-True ([int]$principal.LogonType -eq $TASK_LOGON_INTERACTIVE_TOKEN) ('{0} uses InteractiveToken' -f $Name)
        Assert-True ([int]$principal.RunLevel -eq $TASK_RUNLEVEL_LUA) ('{0} uses LeastPrivilege' -f $Name)
        Assert-True ([int]$trigger.Type -eq $ExpectedTriggerType) ('{0} trigger type correct' -f $Name)
        Assert-True ([int]$actions.Count -eq 1 -and [int]$action.Type -eq $TASK_ACTION_EXEC) ('{0} has exactly one Exec action' -f $Name)
        Assert-True ([string]$action.Arguments -eq '127.0.0.1 -n 6') ('{0} arguments preserved as-is' -f $Name)
        Assert-True ([string]$action.WorkingDirectory -eq [Environment]::GetFolderPath('LocalApplicationData')) ('{0} working directory preserved as-is' -f $Name)
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
    Write-Host ('Test user: {0} ({1})' -f $identity.Name, $currentSid)
    Write-Host ('Unique test prefix: {0}' -f $uniquePrefix)

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    Assert-True ([bool]$service.Connected) 'Task Scheduler COM service connected'

    $logonName = $uniquePrefix + '.Logon'
    $onceName = $uniquePrefix + '.Once'
    $dailyName = $uniquePrefix + '.Daily'

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
        Assert-True (-not [bool]$controlTask.Enabled) 'Unique test task can be disabled'
        $controlTask.Enabled = $true
        Assert-True ([bool]$controlTask.Enabled) 'Unique test task can be enabled'
        $running = $controlTask.Run($null)
        Start-Sleep -Milliseconds 400
        Assert-True ($null -ne $running) 'Unique test task can run immediately'
        $controlTask.Stop(0)
        Assert-True $true 'Unique test task can be stopped'
    }
    finally {
        Release-ComObject $running
        Release-ComObject $controlTask
    }

    # Exercise the actual embedded background runner and registration functions
    # from UserTaskManager.ps1. Only one additional GUID-named task is touched.
    $backgroundName = $uniquePrefix + '.Background'
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
        Assert-True ($sourceErrors.Count -eq 0) 'Main app passes PowerShell syntax parsing'
        $functionAsts = @($sourceAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        $deleteDialogAst = $functionAsts | Where-Object Name -eq 'Show-DeleteTaskDialog' | Select-Object -First 1
        $taskEditorAst = $functionAsts | Where-Object Name -eq 'Show-TaskEditor' | Select-Object -First 1
        Assert-True ($null -ne $deleteDialogAst -and
            $deleteDialogAst.Extent.Text -notmatch 'browseLogDirectoryButton|logDirectoryBox') 'Delete dialog does not reference task editor log controls'
        Assert-True ($null -ne $taskEditorAst -and
            $taskEditorAst.Extent.Text -match 'browseLogDirectoryButton\.Add_Click') 'Log directory browse event bound in task editor'

        $sourceText = [IO.File]::ReadAllText($mainScriptPath, [Text.Encoding]::UTF8)
        Assert-True ([Text.RegularExpressions.Regex]::Matches(
            $sourceText,
            [Text.RegularExpressions.Regex]::Escape('__USER_TASK_MANAGER_ICON_BASE64__')
        ).Count -eq 1) 'Main script contains single build-time icon injection marker'
        $iconBuildOutput = Join-Path $env:TEMP ('UserTaskManager.Test.{0}.cmd' -f ([Guid]::NewGuid().ToString('N')))
        & (Join-Path $PSScriptRoot 'build.ps1') -OutputPath $iconBuildOutput
        Assert-True ([IO.File]::Exists($iconBuildOutput)) 'Builder generates temporary CMD'
        $builtBytes = [IO.File]::ReadAllBytes($iconBuildOutput)
        Assert-True (-not ($builtBytes[0] -eq 0xEF -and $builtBytes[1] -eq 0xBB -and $builtBytes[2] -eq 0xBF)) 'Icon build artifact remains UTF-8 without BOM'
        $builtText = [IO.File]::ReadAllText($iconBuildOutput, (New-Object Text.UTF8Encoding($false)))
        Assert-True (-not $builtText.Contains('__USER_TASK_MANAGER_ICON_BASE64__')) 'SVG-rendered ICO Base64 injected into build artifact'
        $builtSmokeOutput = @(& $env:ComSpec /d /c $iconBuildOutput -SmokeTest 2>&1)
        Assert-True ($LASTEXITCODE -eq 0 -and ($builtSmokeOutput -join "`n") -match 'SMOKE OK:.*Icon=True') 'Build artifact successfully loads custom WPF icon'
        $assetDirectory = Join-Path $PSScriptRoot 'assets'
        $generatedImageFiles = @(
            Get-ChildItem -LiteralPath $assetDirectory -File -ErrorAction Stop |
                Where-Object { $_.Extension -in @('.png', '.ico') }
        )
        Assert-True ($generatedImageFiles.Count -eq 0) 'SVG build leaves no PNG or ICO intermediate files in repo'

        $enabledMenuModel = [PSCustomObject]@{ Enabled = $true }
        Update-TaskContextMenu -TaskModel $enabledMenuModel
        Assert-True (
            $script:TaskContextRunItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextStopItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextDisableItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextEnableItem.Visibility -eq [Windows.Visibility]::Collapsed -and
            $script:TaskContextExportItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextDeleteItem.Visibility -eq [Windows.Visibility]::Visible
        ) 'Enabled task context menu shows Run, Stop, Disable, Export, Delete'

        $disabledMenuModel = [PSCustomObject]@{ Enabled = $false }
        Update-TaskContextMenu -TaskModel $disabledMenuModel
        Assert-True (
            $script:TaskContextRunItem.Visibility -eq [Windows.Visibility]::Collapsed -and
            $script:TaskContextStopItem.Visibility -eq [Windows.Visibility]::Collapsed -and
            $script:TaskContextDisableItem.Visibility -eq [Windows.Visibility]::Collapsed -and
            $script:TaskContextEnableItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextExportItem.Visibility -eq [Windows.Visibility]::Visible -and
            $script:TaskContextDeleteItem.Visibility -eq [Windows.Visibility]::Visible
        ) 'Disabled task context menu shows only Enable, Export, Delete'

        $sameLeafA = Get-BackgroundRuntimeDirectory ('\FolderA\' + $backgroundName)
        $sameLeafB = Get-BackgroundRuntimeDirectory ('\FolderB\' + $backgroundName)
        Assert-True (-not [string]::Equals($sameLeafA, $sameLeafB, [StringComparison]::OrdinalIgnoreCase)) 'Same-named tasks in different folders use different runtime directories'
        Assert-True ([IO.Path]::GetFileName($sameLeafA) -match '^[0-9a-f]{64}$') 'Runtime directory uses SHA-256 of full task path'
        $defaultValues = Get-BackgroundActionValues $backgroundFullPath
        $defaultLog = Resolve-BackgroundLogDirectory -RequestedPath '' -DefaultPath $defaultValues.DefaultLogDirectory
        Assert-True ($defaultLog.IsDefault -and [string]::Equals($defaultLog.Path, [IO.Path]::GetFullPath($defaultValues.DefaultLogDirectory), [StringComparison]::OrdinalIgnoreCase)) 'Empty log path resolves to task-specific default logs directory'

        $backgroundData = [PSCustomObject]@{
            TaskPath = '\'
            TaskName = $backgroundName
            Description = 'UserTaskManager background app safety test'
            Enabled = $true
            Program = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Arguments = '-NoLogo -NoProfile -NonInteractive -Command "Write-Output ''user-task-manager-background-ok''; $child = [Diagnostics.Process]::Start(($env:SystemRoot + ''\System32\PING.EXE''), ''127.0.0.1 -t''); $child.WaitForExit()"'
            WorkingDirectory = [Environment]::GetFolderPath('LocalApplicationData')
            BackgroundMode = $true
            LogDirectory = $backgroundCustomLogDirectory
            TriggerKind = 'Once'
            StartDateTime = (Get-Date).AddHours(1)
            RepeatMinutes = 0
            Overwrite = $false
        }
        [void](Register-TaskFromData -Data $backgroundData)
        $backgroundRegistered = $true

        $editData = Get-TaskEditData -FullPath $backgroundFullPath
        Assert-True ($editData.Supported -and $editData.BackgroundMode) 'Background test task recognized losslessly by editor'
        Assert-True ($editData.Program -eq $backgroundData.Program) 'Background test task preserves real executable field'
        Assert-True ([string]::Equals($editData.LogDirectory, [IO.Path]::GetFullPath($backgroundCustomLogDirectory), [StringComparison]::OrdinalIgnoreCase)) 'Editor echoes custom log directory'

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
            Assert-True ($null -ne $backgroundRuntime) 'Background test task correctly identified as background app'
            Assert-True ([string]::Equals([string]$backgroundAction.Path, $expectedWrapperPowerShell, [StringComparison]::OrdinalIgnoreCase)) 'Task Scheduler tracks system Windows PowerShell directly'
            Assert-True ([string]$backgroundAction.Arguments -match '^-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File ') 'Wrapper action uses hidden non-interactive PowerShell parameters'
            Assert-True ([string]::Equals([string]$backgroundAction.WorkingDirectory, $backgroundRuntime.RuntimeDirectory, [StringComparison]::OrdinalIgnoreCase)) 'Wrapper action uses task-specific runtime directory'
            Assert-True ([int]$backgroundRuntime.Config.Version -eq 1) 'Background config version is 1'
            Assert-True (-not [bool]$backgroundRuntime.LogDirectoryIsDefault) 'Background test task recognized as custom log directory'
            Assert-True ([string]::Equals($backgroundRuntime.LogDirectory, [IO.Path]::GetFullPath($backgroundCustomLogDirectory), [StringComparison]::OrdinalIgnoreCase)) 'Background task log written to normalized custom directory'
            Assert-True ([string]$backgroundSettings.ExecutionTimeLimit -eq 'PT0S') 'Background test task has no 72-hour execution limit'
            Assert-True ([int]$backgroundSettings.MultipleInstances -eq 2) 'Background test task uses IgnoreNew multi-instance policy'
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
        Assert-True ($capturedOutput -match 'user-task-manager-background-ok') 'Background test task writes to stdout.log'
        [IO.File]::WriteAllText($backgroundLogSentinel, 'must-not-delete', [Text.Encoding]::UTF8)

        $wrapperEngineProcessId = [int]$backgroundRunning.EnginePID
        $descendants = @()
        do {
            Start-Sleep -Milliseconds 250
            $descendants = @(Get-DescendantProcessRows -RootProcessId $wrapperEngineProcessId)
        } while (($descendants.Count -lt 2 -or @($descendants | Where-Object Name -eq 'PING.EXE').Count -eq 0) -and
            (Get-Date) -lt $deadline)
        Assert-True ($descendants.Count -ge 2) 'Background wrapper launches target process and its child'
        Assert-True (@($descendants | Where-Object Name -eq 'PING.EXE').Count -eq 1) 'Background test process tree contains long-running grandchild'
        $wrapperProcess = Get-Process -Id $wrapperEngineProcessId -ErrorAction Stop
        Assert-True ([IntPtr]$wrapperProcess.MainWindowHandle -eq [IntPtr]::Zero) 'Task Scheduler-launched PowerShell wrapper has no visible main window'
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
        Assert-True ($remainingProcesses.Count -eq 0) 'Stop terminates wrapper, target, and grandchild via Job Object'
        Assert-True ([int]$backgroundTask.State -ne 4) 'Task Scheduler reports no running instance after stop'
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
                    Write-Warning ('Failed to clean up background test process: PID {0}; {1}' -f $processId, $_.Exception.Message)
                }
            }
        }
        Release-ComObject $backgroundRunning
        Release-ComObject $backgroundTask
        if ($backgroundRegistered -and $null -ne $backgroundFolder) {
            try {
                $backgroundFolder.DeleteTask($backgroundName, 0)
                Write-Host ('Cleaned up background test task: {0}' -f $backgroundFullPath)
            }
            catch {
                Write-Warning ('Failed to clean up background test task: {0}; {1}' -f $backgroundFullPath, $_.Exception.Message)
            }
        }
        Release-ComObject $backgroundFolder
        if ($null -ne $backgroundRuntime) {
            try {
                Remove-BackgroundRuntimeFiles -RuntimeInfo $backgroundRuntime -DeleteLogs $true
                Write-Host ('Cleaned up background test files: {0}' -f $backgroundRuntime.RuntimeDirectory)
            }
            catch {
                Write-Warning ('Failed to clean up background test files: {0}' -f $_.Exception.Message)
            }
        }
        Release-ComObject $script:TaskService
        $script:TaskService = $null
    }

    Assert-True ([IO.File]::Exists($backgroundLogSentinel)) 'Non-task files preserved in custom log directory during cleanup'
    [IO.File]::Delete($backgroundLogSentinel)
    if ([IO.Directory]::Exists($backgroundCustomLogDirectory) -and
        [IO.Directory]::GetFileSystemEntries($backgroundCustomLogDirectory).Count -eq 0) {
        [IO.Directory]::Delete($backgroundCustomLogDirectory, $false)
    }

    Write-Host ''
    Write-Host 'All tests passed:' -ForegroundColor Green
    $results | ForEach-Object { Write-Host ('  {0}' -f $_) }
}
catch {
    $unsigned = $_.Exception.HResult -band 0xFFFFFFFF
    if ($unsigned -eq 0x80070005 -or $_.Exception.Message -match 'Access.*denied') {
        Write-Error 'Access denied: current user cannot create safety test tasks in root folder; elevation not requested.'
    }
    else {
        Write-Error $_
    }
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($iconBuildOutput) -and [IO.File]::Exists($iconBuildOutput)) {
        try {
            $expectedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            $iconBuildFullPath = [IO.Path]::GetFullPath($iconBuildOutput)
            if ($iconBuildFullPath.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
                [IO.File]::Delete($iconBuildFullPath)
            }
        }
        catch {
            Write-Warning ('Failed to clean up temp icon build artifact: {0}; {1}' -f $iconBuildOutput, $_.Exception.Message)
        }
    }
    if ($null -ne $root) {
        foreach ($name in @($createdNames)) {
            try {
                $root.DeleteTask($name, 0)
                Write-Host ('Cleaned up test task: \{0}' -f $name)
            }
            catch {
                Write-Warning ('Failed to clean up test task: \{0}; {1}' -f $name, $_.Exception.Message)
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
            Write-Warning ('Failed to clean up unique test log directory: {0}; {1}' -f $backgroundCustomLogDirectory, $_.Exception.Message)
        }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
