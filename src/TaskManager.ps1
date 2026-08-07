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

function Convert-BitmaskToString {
    param(
        [Parameter(Mandatory = $true)][int]$Mask,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][int[]]$Values
    )
    $parts = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt [Math]::Min($Names.Count, $Values.Count); $i++) {
        if (($Mask -band $Values[$i]) -ne 0) {
            $parts.Add($Names[$i])
        }
    }
    if ($parts.Count -eq 0) { return '无' }
    return ($parts -join '、')
}

function Convert-DaysOfWeekMask {
    param([int]$Mask)
    return Convert-BitmaskToString -Mask $Mask -Names $script:DayOfWeekNames -Values $script:DayOfWeekMasks
}

function Convert-MonthsOfYearMask {
    param([int]$Mask)
    return Convert-BitmaskToString -Mask $Mask -Names $script:MonthNames -Values $script:MonthMasks
}

function Convert-WeeksOfMonthMask {
    param([int]$Mask)
    return Convert-BitmaskToString -Mask $Mask -Names $script:WeekOfMonthNames -Values $script:WeekOfMonthMasks
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
                    3 {
                        $days = try { Convert-DaysOfWeekMask ([int]$trigger.DaysOfWeek) } catch { '?' }
                        $interval = try { [int]$trigger.WeeksInterval } catch { 1 }
                        if ($interval -le 1) { '每周 {0}' -f $days }
                        else { '每 {0} 周 {1}' -f $interval, $days }
                    }
                    4 {
                        $daysOfMonth = try { Convert-BitmaskToString -Mask ([int]$trigger.DaysOfMonth) -Names ([string[]](1..31 | ForEach-Object { '{0}日' -f $_ })) -Values ([int[]](1..31 | ForEach-Object { [Math]::Pow(2, $_ - 1) })) } catch { '?' }
                        $months = try { Convert-MonthsOfYearMask ([int]$trigger.MonthsOfYear) } catch { '' }
                        if ($months -and $months -ne '无') { '每月 {0}（{1}）' -f $daysOfMonth, $months }
                        else { '每月 {0}' -f $daysOfMonth }
                    }
                    5 {
                        $dow = try { Convert-DaysOfWeekMask ([int]$trigger.DaysOfWeek) } catch { '?' }
                        $weeks = try { Convert-WeeksOfMonthMask ([int]$trigger.WeeksOfMonth) } catch { '?' }
                        $months = try { Convert-MonthsOfYearMask ([int]$trigger.MonthsOfYear) } catch { '' }
                        $base = '每月 {0} 的 {1}' -f $weeks, $dow
                        if ($months -and $months -ne '无') { '{0}（{1}）' -f $base, $months }
                        else { $base }
                    }
                    6 { '空闲时' }
                    7 {
                        $delay = try { [string]$trigger.Delay } catch { '' }
                        if (-not [string]::IsNullOrWhiteSpace($delay)) {
                            '注册时（延迟 {0}）' -f (Convert-IsoDurationToText $delay)
                        }
                        else { '注册时' }
                    }
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
                Clear-ComObject $trigger
            }
        }
    }
    finally {
        Clear-ComObject $triggers
    }
    if ($summaries.Count -eq 0) { return '无触发器' }
    return ($summaries -join '；')
}

function Format-SummaryArgument {
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
                    $summary = Format-SummaryArgument ([string]$action.Path)
                    if (-not [string]::IsNullOrWhiteSpace([string]$action.Arguments)) {
                        $summary += ' ' + [string]$action.Arguments
                    }
                    $summaries.Add($summary)
                }
                elseif ([int]$action.Type -eq $script:TASK_ACTION_SHOW_MESSAGE) {
                    $summaries.Add(('消息：{0}' -f [string]$action.Title))
                }
                else {
                    $summaries.Add(('不支持的操作类型 {0}' -f $action.Type))
                }
            }
            catch {
                $summaries.Add('无法读取的操作')
            }
            finally {
                Clear-ComObject $action
            }
        }
    }
    finally {
        Clear-ComObject $actions
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
    try {
        $actions = $Definition.Actions
        $actCount = [int]$actions.Count
        $actionIndex = 0
        $backgroundSummary = ''
        foreach ($a in @($actions)) {
            try {
                if ([int]$a.Type -eq $script:TASK_ACTION_EXEC) {
                    $actionIndex++
                    if (-not $backgroundSummary) {
                        $runtimeInfo = Get-BackgroundRuntimeInfo -FullTaskPath $FullTaskPath -Action $a
                        if ($null -ne $runtimeInfo) {
                            $backgroundSummary = '后台应用：' + (Format-SummaryArgument ([string]$runtimeInfo.Config.Executable))
                            if (-not [string]::IsNullOrWhiteSpace([string]$runtimeInfo.Config.Arguments)) {
                                $backgroundSummary += ' ' + [string]$runtimeInfo.Config.Arguments
                            }
                            $backgroundSummary += '；日志：' + $runtimeInfo.LogDirectory
                            if ($actionIndex -gt 1) {
                                $backgroundSummary += '（操作 {0}）' -f $actionIndex
                            }
                        }
                    }
                }
            }
            finally {
                Clear-ComObject $a
            }
        }
        if ($backgroundSummary) { return $backgroundSummary }
    }
    finally {
        Clear-ComObject $actions
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
        Clear-ComObject $principal
        Clear-ComObject $definition
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
                Clear-ComObject $task
            }
        }
    }
    finally {
        Clear-ComObject $tasks
        Clear-ComObject $folder
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
                Clear-ComObject $child
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
        Clear-ComObject $children
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

function Update-FolderTree {
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
        Clear-ComObject $rootFolder
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

function Update-TaskList {
    param([string]$FolderPath)
    if ($script:IsBusy) { return }
    Set-Busy -Busy $true -Status ('正在读取 {0} ...' -f $FolderPath)
    try {
        $script:CurrentFolderPath = Resolve-FolderPath $FolderPath
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

function Update-All {
    if ($script:IsBusy) { return }
    Set-Busy -Busy $true -Status '正在刷新任务文件夹...'
    try {
        $errors = @(Update-FolderTree)
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
        Clear-ComObject $task
        Clear-ComObject $folder
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
        Clear-ComObject $task
        Clear-ComObject $folder
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
        # Find first Exec action and check background runtime.
        $actCount = [int]$actions.Count
        for ($ai = 1; $ai -le $actCount; $ai++) {
            $a = $null
            try {
                $a = $actions.Item($ai)
                if ([int]$a.Type -eq $script:TASK_ACTION_EXEC) {
                    $action = $a
                    return Get-BackgroundRuntimeInfo -FullTaskPath $FullPath -Action $a
                }
            }
            finally {
                if ($null -ne $a -and $a -ne $action) { Clear-ComObject $a }
            }
        }
        return $null
    }
    finally {
        Clear-ComObject $action
        Clear-ComObject $actions
        Clear-ComObject $definition
        Clear-ComObject $task
        Clear-ComObject $folder
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

        # Per-action validation (replaces the old single-action gate).
        $actionCount = [int]$actions.Count
        if ($actionCount -eq 0) {
            $reasons.Add('任务没有操作')
        }
        else {
            for ($aIdx = 1; $aIdx -le $actionCount; $aIdx++) {
                $a = $null
                try {
                    $a = $actions.Item($aIdx)
                    $aType = [int]$a.Type
                    if ($aType -ne $script:TASK_ACTION_EXEC -and $aType -ne $script:TASK_ACTION_SHOW_MESSAGE) {
                        $reasons.Add(('操作 {0} 的类型不支持' -f $aIdx))
                    }
                }
                catch {
                    $reasons.Add(('无法读取操作 {0}' -f $aIdx))
                }
                finally {
                    Clear-ComObject $a
                }
            }
        }

        # Per-trigger validation (replaces the old single-trigger gate).
        $triggerCount = [int]$triggers.Count
        if ($triggerCount -eq 0) {
            $reasons.Add('任务没有触发器')
        }
        else {
            $allowedEditTriggerTypes = @(
                $script:TASK_TRIGGER_TIME, $script:TASK_TRIGGER_DAILY,
                $script:TASK_TRIGGER_WEEKLY, $script:TASK_TRIGGER_MONTHLY,
                $script:TASK_TRIGGER_MONTHLYDOW, $script:TASK_TRIGGER_IDLE,
                $script:TASK_TRIGGER_REGISTRATION, $script:TASK_TRIGGER_LOGON
            )
            for ($tIdx = 1; $tIdx -le $triggerCount; $tIdx++) {
                $t = $null
                try {
                    $t = $triggers.Item($tIdx)
                    $tType = [int]$t.Type
                    if ($allowedEditTriggerTypes -notcontains $tType) {
                        $reasons.Add(('触发器 {0} 的类型不支持' -f $tIdx))
                    }
                }
                catch {
                    $reasons.Add(('无法读取触发器 {0}' -f $tIdx))
                }
                finally {
                    Clear-ComObject $t
                }
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
            '/t:Task/t:Triggers/*[not(self::t:TimeTrigger or self::t:CalendarTrigger or self::t:LogonTrigger or self::t:IdleTrigger or self::t:RegistrationTrigger)]',
            $ns
        ))
        if ($unsupportedTriggerNodes.Count -gt 0) {
            $reasons.Add('XML 中包含高级触发器')
        }
        $unsupportedActionNodes = @($xml.SelectNodes(
            '/t:Task/t:Actions/*[not(self::t:Exec or self::t:ShowMessage)]',
            $ns
        ))
        if ($unsupportedActionNodes.Count -gt 0) {
            $reasons.Add('XML 中包含 COM Handler、邮件或其他高级操作')
        }
        foreach ($trNode in @($xml.SelectNodes('/t:Task/t:Triggers/*', $ns))) {
            $allowedTriggerChildren = switch ($trNode.LocalName) {
                'TimeTrigger'     { @('Repetition', 'StartBoundary', 'Enabled') }
                'CalendarTrigger' { @('Repetition', 'StartBoundary', 'Enabled',
                                      'ScheduleByDay', 'ScheduleByWeek',
                                      'ScheduleByMonth', 'ScheduleByMonthDayOfWeek') }
                'LogonTrigger'    { @('StartBoundary', 'EndBoundary', 'Enabled', 'UserId') }
                'IdleTrigger'     { @('Repetition', 'StartBoundary', 'EndBoundary', 'Enabled') }
                'RegistrationTrigger' { @('Repetition', 'StartBoundary', 'EndBoundary', 'Enabled', 'Delay') }
                default { @() }
            }
            foreach ($child in @($trNode.ChildNodes)) {
                if ($child.NodeType -eq [Xml.XmlNodeType]::Element -and
                    $allowedTriggerChildren -notcontains $child.LocalName) {
                    $reasons.Add(('触发器属性 {0} 不受支持' -f $child.LocalName))
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

        # Check background runtime on the first Exec action (was single-action).
        $action = $null
        $firstExecAction = $null
        $firstExecIndex = -1
        for ($aIdx = 1; $aIdx -le $actionCount; $aIdx++) {
            $a = $null
            try {
                $a = $actions.Item($aIdx)
                if ([int]$a.Type -eq $script:TASK_ACTION_EXEC) {
                    $firstExecAction = $a
                    $firstExecIndex = $aIdx
                    break
                }
            }
            finally { if ($null -ne $a -and $a -ne $firstExecAction) { Clear-ComObject $a } }
        }
        if ($null -ne $firstExecAction) {
            $action = $firstExecAction
            $backgroundInfo = Get-BackgroundRuntimeInfo -FullTaskPath $FullPath -Action $firstExecAction
            if ($null -eq $backgroundInfo -and (Test-ActionTargetsBackgroundRunner -FullTaskPath $FullPath -Action $firstExecAction)) {
                $reasons.Add('后台运行配置缺失或与任务路径不匹配')
            }
        }

        if ($reasons.Count -gt 0) {
            return [PSCustomObject]@{
                Supported = $false
                Reason = '包含不支持的高级配置：' + ($reasons -join '；')
            }
        }

        # --- Build Actions[] array from all registered actions ---
        $actionList = New-Object 'System.Collections.Generic.List[object]'
        for ($aIdx = 1; $aIdx -le $actionCount; $aIdx++) {
            $a = $null
            try {
                $a = $actions.Item($aIdx)
                $aType = [int]$a.Type
                if ($aType -eq $script:TASK_ACTION_EXEC) {
                    $aProgram = [string]$a.Path
                    $aArgs = [string]$a.Arguments
                    $aWd = [string]$a.WorkingDirectory
                    # Check if this specific Exec action is a background app.
                    $aBgInfo = Get-BackgroundRuntimeInfo -FullTaskPath $FullPath -Action $a
                    if ($null -ne $aBgInfo) {
                        $aProgram = [string]$aBgInfo.Config.Executable
                        $aArgs = [string]$aBgInfo.Config.Arguments
                        $aWd = [string]$aBgInfo.Config.WorkingDirectory
                    }
                    $actionList.Add([PSCustomObject]@{
                        Type = 'Exec'
                        Program = $aProgram
                        Arguments = $aArgs
                        WorkingDirectory = $aWd
                        Title = ''
                        MessageBody = ''
                    })
                }
                elseif ($aType -eq $script:TASK_ACTION_SHOW_MESSAGE) {
                    $actionList.Add([PSCustomObject]@{
                        Type = 'ShowMessage'
                        Program = ''
                        Arguments = ''
                        WorkingDirectory = ''
                        Title = [string]$a.Title
                        MessageBody = [string]$a.MessageBody
                    })
                }
            }
            catch {
                $actionList.Add([PSCustomObject]@{
                    Type = 'Unknown'
                    Program = ''; Arguments = ''; WorkingDirectory = ''
                    Title = ''; MessageBody = ''
                })
            }
            finally {
                if ($null -ne $a -and $a -ne $firstExecAction) { Clear-ComObject $a }
            }
        }

        # --- Build Triggers[] array from all registered triggers ---
        $triggerList = New-Object 'System.Collections.Generic.List[object]'
        for ($tIdx = 1; $tIdx -le $triggerCount; $tIdx++) {
            $t = $null
            try {
                $t = $triggers.Item($tIdx)
                $tType = [int]$t.Type
                $tKind = switch ($tType) {
                    1 { '单次' }
                    2 { '每天' }
                    3 { '每周' }
                    4 { '每月' }
                    5 { '每月（星期）' }
                    6 { '空闲时' }
                    7 { '注册时' }
                    9 { '登录时' }
                    default { '单次' }
                }
                $tStart = Get-Date
                if ($tType -notin @($script:TASK_TRIGGER_LOGON, $script:TASK_TRIGGER_IDLE, $script:TASK_TRIGGER_REGISTRATION)) {
                    try { $tStart = [DateTime]$t.StartBoundary } catch {}
                }
                $tRepeatMins = 0
                $tRandomDelay = ''
                try {
                    $tInterval = [string]$t.Repetition.Interval
                    if ($tInterval -match '^PT(\d+)M$') { $tRepeatMins = [int]$matches[1] }
                    $tRandomDelay = try { [string]$t.Repetition.RandomDelay } catch { '' }
                }
                catch {}

                $tDaysOfWeek = try { [int]$t.DaysOfWeek } catch { 0 }
                $tWeeksInterval = try { [int]$t.WeeksInterval } catch { 1 }
                $tDaysOfMonth = try { [int]$t.DaysOfMonth } catch { 0 }
                $tMonthsOfYear = try { [int]$t.MonthsOfYear } catch { 0 }
                $tWeeksOfMonth = try { [int]$t.WeeksOfMonth } catch { 0 }
                $tDelay = try { [string]$t.Delay } catch { '' }

                $triggerList.Add([PSCustomObject]@{
                    Kind = $tKind
                    StartDate = $tStart.Date
                    StartTime = $tStart.ToString('HH:mm')
                    RepeatMinutes = $tRepeatMins
                    RandomDelay = $tRandomDelay
                    DaysOfWeek = $tDaysOfWeek
                    WeeksInterval = $tWeeksInterval
                    DaysOfMonth = $tDaysOfMonth
                    MonthsOfYear = $tMonthsOfYear
                    WeeksOfMonth = $tWeeksOfMonth
                    Delay = $tDelay
                })
            }
            catch {
                $triggerList.Add([PSCustomObject]@{
                    Kind = '单次'
                    StartDate = (Get-Date).Date; StartTime = '00:00'
                    RepeatMinutes = 0; RandomDelay = ''
                    DaysOfWeek = 0; WeeksInterval = 1
                    DaysOfMonth = 0; MonthsOfYear = 0; WeeksOfMonth = 0
                    Delay = ''
                })
            }
            finally {
                Clear-ComObject $t
            }
        }

        # --- Scalar fields (first action / first trigger, for backward compat) ---
        $firstAction = if ($actionList.Count -gt 0) { $actionList[0] } else { $null }
        $firstTrigger = if ($triggerList.Count -gt 0) { $triggerList[0] } else { $null }

        $displayProgram = if ($firstAction) { $firstAction.Program } else { '' }
        $displayArguments = if ($firstAction) { $firstAction.Arguments } else { '' }
        $displayWorkingDirectory = if ($firstAction) { $firstAction.WorkingDirectory } else { '' }
        $triggerKind = if ($firstTrigger) { $firstTrigger.Kind } else { '单次' }
        $start = if ($firstTrigger) { $firstTrigger.StartDate.Date.Add([TimeSpan]::Parse($firstTrigger.StartTime)) } else { Get-Date }
        $repeatMinutes = if ($firstTrigger) { $firstTrigger.RepeatMinutes } else { 0 }

        $backgroundMode = $false
        $displayLogDirectory = ''
        $displayEnvironment = $null
        if ($null -ne $backgroundInfo) {
            $displayProgram = [string]$backgroundInfo.Config.Executable
            $displayArguments = [string]$backgroundInfo.Config.Arguments
            $displayWorkingDirectory = [string]$backgroundInfo.Config.WorkingDirectory
            $backgroundMode = $true
            if (-not [bool]$backgroundInfo.LogDirectoryIsDefault) {
                $displayLogDirectory = [string]$backgroundInfo.LogDirectory
            }
            if ($null -ne $backgroundInfo.PSObject.Properties['Environment']) {
                $displayEnvironment = $backgroundInfo.Environment
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
            Environment = $displayEnvironment
            TriggerKind = $triggerKind
            StartDate = $start.Date
            StartTime = $start.ToString('HH:mm')
            RepeatMinutes = $repeatMinutes
            Actions = [object[]]$actionList
            Triggers = [object[]]$triggerList
        }
    }
    finally {
        Clear-ComObject $firstExecAction
        Clear-ComObject $action
        Clear-ComObject $principal
        Clear-ComObject $triggers
        Clear-ComObject $actions
        Clear-ComObject $definition
        Clear-ComObject $task
        Clear-ComObject $folder
    }
}

function Initialize-TaskFolder {
    param([string]$FolderPath)
    Connect-TaskService
    $normalized = Resolve-FolderPath $FolderPath
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
            Clear-ComObject $parent
            $parent = $nextFolder
            $currentPath = $nextPath
        }
        $result = $parent
        $parent = $null
        return $result
    }
    finally {
        Clear-ComObject $parent
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
        $folder = Initialize-TaskFolder $Data.TaskPath
        if (-not [string]::IsNullOrWhiteSpace($OriginalFullPath)) {
            $sourceParts = Split-RegisteredTaskPath $OriginalFullPath
            $sourceFolder = $script:TaskService.GetFolder($sourceParts.Folder)
            $sourceTask = $sourceFolder.GetTask($sourceParts.Name)
            $definition = $sourceTask.Definition
            try {
                $sourceActionsForRuntime = $definition.Actions
                $srcActCount = [int]$sourceActionsForRuntime.Count
                for ($sai = 1; $sai -le $srcActCount; $sai++) {
                    $sa = $null
                    try {
                        $sa = $sourceActionsForRuntime.Item($sai)
                        if ([int]$sa.Type -eq $script:TASK_ACTION_EXEC) {
                            $sourceActionForRuntime = $sa
                            $oldRuntimeInfo = Get-BackgroundRuntimeInfo -FullTaskPath $OriginalFullPath -Action $sa
                            break
                        }
                    }
                    finally {
                        if ($null -ne $sa -and $sa -ne $sourceActionForRuntime) { Clear-ComObject $sa }
                    }
                }
            }
            finally {
                Clear-ComObject $sourceActionForRuntime
                $sourceActionForRuntime = $null
                Clear-ComObject $sourceActionsForRuntime
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

        $triggerList = @()
        if ($null -ne $Data.PSObject.Properties['Triggers'] -and $Data.Triggers.Count -gt 0) {
            $triggerList = @($Data.Triggers)
        }
        else {
            # Backward compat: synthesize from scalar fields.
            $triggerList = @([PSCustomObject]@{
                Kind = [string]$Data.TriggerKind
                StartDate = $Data.StartDateTime.Date
                StartTime = $Data.StartDateTime.ToString('HH:mm')
                RepeatMinutes = [int]$Data.RepeatMinutes
                RandomDelay = ''
                DaysOfWeek = 0; WeeksInterval = 1
                DaysOfMonth = 0; MonthsOfYear = 0; WeeksOfMonth = 0
                Delay = ''
            })
        }

        foreach ($trgData in $triggerList) {
            $triggerType = switch ($trgData.Kind) {
                '登录时' { $script:TASK_TRIGGER_LOGON }
                '每天'   { $script:TASK_TRIGGER_DAILY }
                '每周'   { $script:TASK_TRIGGER_WEEKLY }
                '每月'   { $script:TASK_TRIGGER_MONTHLY }
                '每月（星期）' { $script:TASK_TRIGGER_MONTHLYDOW }
                '空闲时' { $script:TASK_TRIGGER_IDLE }
                '注册时' { $script:TASK_TRIGGER_REGISTRATION }
                default  { $script:TASK_TRIGGER_TIME }
            }
            $trigger = $triggers.Create($triggerType)
            $trigger.Enabled = $true

            if ($trgData.Kind -eq '登录时') {
                $trigger.UserId = $script:CurrentSid
            }
            elseif ($trgData.Kind -eq '注册时') {
                if (-not [string]::IsNullOrWhiteSpace([string]$trgData.Delay)) {
                    $trigger.Delay = [string]$trgData.Delay
                }
            }
            elseif ($trgData.Kind -ne '空闲时') {
                # Time-based triggers: set StartBoundary.
                $startDt = $trgData.StartDate.Date.Add([TimeSpan]::Parse($trgData.StartTime))
                $trigger.StartBoundary = $startDt.ToString('yyyy-MM-ddTHH:mm:ss')
            }

            # Type-specific sub-fields.
            switch ($triggerType) {
                $script:TASK_TRIGGER_DAILY { $trigger.DaysInterval = 1 }
                $script:TASK_TRIGGER_WEEKLY {
                    if ([int]$trgData.DaysOfWeek -ne 0) { $trigger.DaysOfWeek = [int]$trgData.DaysOfWeek }
                    if ([int]$trgData.WeeksInterval -gt 0) { $trigger.WeeksInterval = [int]$trgData.WeeksInterval }
                }
                $script:TASK_TRIGGER_MONTHLY {
                    if ([int]$trgData.DaysOfMonth -ne 0) { $trigger.DaysOfMonth = [int]$trgData.DaysOfMonth }
                    if ([int]$trgData.MonthsOfYear -ne 0) { $trigger.MonthsOfYear = [int]$trgData.MonthsOfYear }
                }
                $script:TASK_TRIGGER_MONTHLYDOW {
                    if ([int]$trgData.DaysOfWeek -ne 0) { $trigger.DaysOfWeek = [int]$trgData.DaysOfWeek }
                    if ([int]$trgData.WeeksOfMonth -ne 0) { $trigger.WeeksOfMonth = [int]$trgData.WeeksOfMonth }
                    if ([int]$trgData.MonthsOfYear -ne 0) { $trigger.MonthsOfYear = [int]$trgData.MonthsOfYear }
                }
            }

            # Repetition.
            $repeatMins = [int]$trgData.RepeatMinutes
            if ($repeatMins -gt 0 -and $trgData.Kind -notin @('登录时', '空闲时', '注册时')) {
                $repetition = $trigger.Repetition
                $repetition.Interval = Convert-MinutesToIsoDuration $repeatMins
                $repetition.StopAtDurationEnd = $false
                if ($trgData.Kind -in @('每天', '每周')) {
                    $repetition.Duration = 'P1D'
                }
                elseif ($trgData.Kind -in @('每月', '每月（星期）')) {
                    $repetition.Duration = 'P31D'
                }
                else {
                    $repetition.Duration = 'P7D'
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$trgData.RandomDelay)) {
                    $repetition.RandomDelay = [string]$trgData.RandomDelay
                }
            }

            Clear-ComObject $repetition
            $repetition = $null
            Clear-ComObject $trigger
        }
        $trigger = $null

        $fullPath = Join-TaskFullPath $Data.TaskPath $Data.TaskName
        $effectiveProgram = [string]$Data.Program
        $effectiveArguments = [string]$Data.Arguments
        $effectiveWorkingDirectory = [string]$Data.WorkingDirectory
        if ($backgroundMode) {
            $backgroundInstallState = Install-BackgroundRuntime -Data $Data -FullTaskPath $fullPath -OriginalFullPath $OriginalFullPath
            $effectiveProgram = $backgroundInstallState.Values.ActionPath
            $effectiveArguments = $backgroundInstallState.Values.ActionArguments
            $effectiveWorkingDirectory = $backgroundInstallState.Values.RuntimeDirectory
        }

        $actions = $definition.Actions
        $actions.Clear()

        $actionList = @()
        if ($null -ne $Data.PSObject.Properties['Actions'] -and $Data.Actions.Count -gt 0) {
            $actionList = @($Data.Actions)
        }
        else {
            # Backward compat: synthesize from scalar fields.
            $actionList = @([PSCustomObject]@{
                Type = 'Exec'
                Program = [string]$Data.Program
                Arguments = [string]$Data.Arguments
                WorkingDirectory = [string]$Data.WorkingDirectory
                Title = ''; MessageBody = ''
            })
        }

        $firstExecIndex = -1
        for ($i = 0; $i -lt $actionList.Count; $i++) {
            $actData = $actionList[$i]
            if ($actData.Type -eq 'Exec') {
                $action = $actions.Create($script:TASK_ACTION_EXEC)
                if ($backgroundMode -and $firstExecIndex -lt 0) {
                    $action.Path = $backgroundInstallState.Values.ActionPath
                    $action.Arguments = $backgroundInstallState.Values.ActionArguments
                    $action.WorkingDirectory = $backgroundInstallState.Values.RuntimeDirectory
                    $firstExecIndex = $i
                }
                else {
                    $action.Path = [string]$actData.Program
                    $action.Arguments = [string]$actData.Arguments
                    $action.WorkingDirectory = [string]$actData.WorkingDirectory
                }
            }
            elseif ($actData.Type -eq 'ShowMessage') {
                $action = $actions.Create($script:TASK_ACTION_SHOW_MESSAGE)
                $action.Title = [string]$actData.Title
                $action.MessageBody = [string]$actData.MessageBody
            }
        }
        $action = $null

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
                Clear-ComObject $oldFolder
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
        Clear-ComObject $registeredTask
        Clear-ComObject $action
        Clear-ComObject $actions
        Clear-ComObject $repetition
        Clear-ComObject $trigger
        Clear-ComObject $triggers
        Clear-ComObject $settings
        Clear-ComObject $principal
        Clear-ComObject $registrationInfo
        Clear-ComObject $definition
        Clear-ComObject $sourceTask
        Clear-ComObject $sourceFolder
        Clear-ComObject $sourceActionForRuntime
        Clear-ComObject $sourceActionsForRuntime
        Clear-ComObject $folder
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
        $folder = $script:TaskService.GetFolder((Resolve-FolderPath $FolderPath))
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
        Clear-ComObject $task
        Clear-ComObject $folder
    }
}

