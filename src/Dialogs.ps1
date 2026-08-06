function Show-TaskEditor {
    param(
        [ValidateSet('Create', 'Edit')][string]$Mode,
        $ExistingData
    )

    [xml]$editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="任务" Width="760" Height="880" MinWidth="680" MinHeight="800"
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
        <Label Grid.Row="14" Grid.Column="0" Content="自定义环境变量"
               IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
        <Grid Grid.Row="14" Grid.Column="1" Margin="4,0"
              IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ScrollViewer MaxHeight="120" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="EnvVarsPanel"/>
          </ScrollViewer>
          <Button x:Name="AddEnvVarButton" Grid.Row="1" Width="85" Margin="0,4,0,0"
                  HorizontalAlignment="Left" Content="添加变量"/>
        </Grid>
        <TextBlock Grid.Row="15" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666"
                   TextWrapping="Wrap"
                   Text="仅用于后台应用。变量名和值均不能为空。同名变量将覆盖继承值。"/>
        <Separator Grid.Row="16" Grid.ColumnSpan="2" Margin="0,10"/>
        <Label Grid.Row="17" Grid.Column="0" Content="触发器"/>
        <ComboBox x:Name="TriggerKindBox" Grid.Row="17" Grid.Column="1" Margin="4" SelectedIndex="0">
          <ComboBoxItem Content="登录时"/><ComboBoxItem Content="单次"/><ComboBoxItem Content="每天"/>
        </ComboBox>
        <Label Grid.Row="18" Grid.Column="0" Content="开始日期和时间"/>
        <StackPanel Grid.Row="18" Grid.Column="1" Orientation="Horizontal">
          <DatePicker x:Name="StartDatePicker" Width="180" Margin="4"/>
          <TextBox x:Name="StartTimeBox" Width="90" Margin="4" ToolTip="HH:mm"/>
          <TextBlock Margin="4,7" Text="（登录触发器忽略此项）"/>
        </StackPanel>
        <Label Grid.Row="19" Grid.Column="0" Content="重复间隔（分钟）"/>
        <StackPanel Grid.Row="19" Grid.Column="1" Orientation="Horizontal">
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
    $envVarsPanel = $window.FindName('EnvVarsPanel')
    $addEnvVarButton = $window.FindName('AddEnvVarButton')

    $script:__envVarRows = New-Object 'System.Collections.Generic.List[object]'

    function New-EnvVarRow {
        $row = New-Object Windows.Controls.Grid
        $col1 = New-Object Windows.Controls.ColumnDefinition
        $col1.Width = [Windows.GridLength]::new(130)
        $col2 = New-Object Windows.Controls.ColumnDefinition
        $col2.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $col3 = New-Object Windows.Controls.ColumnDefinition
        $col3.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $col4 = New-Object Windows.Controls.ColumnDefinition
        $col4.Width = [Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($col1)
        [void]$row.ColumnDefinitions.Add($col2)
        [void]$row.ColumnDefinitions.Add($col3)
        [void]$row.ColumnDefinitions.Add($col4)

        $nameBox = New-Object Windows.Controls.TextBox
        $nameBox.Margin = [Windows.Thickness]::new(2, 2, 4, 2)
        [Windows.Controls.Grid]::SetColumn($nameBox, 0)
        [void]$row.Children.Add($nameBox)

        $eqLabel = New-Object Windows.Controls.TextBlock
        $eqLabel.Text = ' = '
        $eqLabel.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $eqLabel.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
        [Windows.Controls.Grid]::SetColumn($eqLabel, 1)
        [void]$row.Children.Add($eqLabel)

        $valueBox = New-Object Windows.Controls.TextBox
        $valueBox.Margin = [Windows.Thickness]::new(4, 2, 2, 2)
        [Windows.Controls.Grid]::SetColumn($valueBox, 2)
        [void]$row.Children.Add($valueBox)

        $removeButton = New-Object Windows.Controls.Button
        $removeButton.Content = '✕'
        $removeButton.Width = 26
        $removeButton.Height = 22
        $removeButton.Margin = [Windows.Thickness]::new(4, 2, 0, 2)
        $removeButton.FontSize = 11
        [Windows.Controls.Grid]::SetColumn($removeButton, 3)
        $removeButton.Add_Click({
            [void]$envVarsPanel.Children.Remove($row)
            [void]$script:__envVarRows.Remove($row)
        })
        [void]$row.Children.Add($removeButton)

        $row.Margin = [Windows.Thickness]::new(0, 0, 0, 2)
        [void]$envVarsPanel.Children.Add($row)
        [void]$script:__envVarRows.Add($row)
        return @{ NameBox = $nameBox; ValueBox = $valueBox }
    }

    $addEnvVarButton.Add_Click({
        [void](New-EnvVarRow)
    })

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
        if ($null -ne $ExistingData.PSObject.Properties['Environment'] -and
            $null -ne $ExistingData.Environment) {
            foreach ($prop in $ExistingData.Environment.PSObject.Properties) {
                $envRow = New-EnvVarRow
                $envRow.NameBox.Text = $prop.Name
                $envRow.ValueBox.Text = [string]$prop.Value
            }
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

    $browseLogDirectoryButton.Add_Click({
        $dialog = $null
        try {
            $dialog = New-Object Windows.Forms.FolderBrowserDialog
            $dialog.Description = '选择后台应用日志目录'
            $dialog.ShowNewFolderButton = $true
            $candidate = [Environment]::ExpandEnvironmentVariables($logDirectoryBox.Text.Trim())
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and [IO.Directory]::Exists($candidate)) {
                $dialog.SelectedPath = [IO.Path]::GetFullPath($candidate)
            }
            if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
                $logDirectoryBox.Text = $dialog.SelectedPath
            }
        }
        catch {
            [void][Windows.MessageBox]::Show(
                $window,
                $_.Exception.Message,
                '无法选择日志目录',
                [Windows.MessageBoxButton]::OK,
                [Windows.MessageBoxImage]::Warning
            )
        }
        finally {
            if ($null -ne $dialog) { $dialog.Dispose() }
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

            $envVars = @{}
            foreach ($row in $script:__envVarRows) {
                $nameBox = $row.Children[0]
                $valueBox = $row.Children[2]
                $key = $nameBox.Text.Trim()
                if ([string]::IsNullOrEmpty($key)) { continue }
                $envVars[$key] = $valueBox.Text
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
                Environment = $envVars
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
               Text="任务删除后无法由本程序恢复。若这是后台应用，wrapper.ps1 和 config.json 会一并删除。"/>
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
$script:MainIconLoaded = Set-MainWindowIcon -Window $script:MainWindow
$script:FolderTree = $script:MainWindow.FindName('FolderTree')
$script:TaskGrid = $script:MainWindow.FindName('TaskGrid')
$script:DetailText = $script:MainWindow.FindName('DetailText')
$script:StatusText = $script:MainWindow.FindName('StatusText')
$script:CountText = $script:MainWindow.FindName('CountText')
$script:RefreshButton = $script:MainWindow.FindName('RefreshButton')
$script:ActionPanel = $script:MainWindow.FindName('CreateButton').Parent

$script:TaskContextMenu = New-Object Windows.Controls.ContextMenu
$script:TaskContextRunItem = New-Object Windows.Controls.MenuItem
$script:TaskContextRunItem.Header = '运行'
$script:TaskContextStopItem = New-Object Windows.Controls.MenuItem
$script:TaskContextStopItem.Header = '结束'
$script:TaskContextDisableItem = New-Object Windows.Controls.MenuItem
$script:TaskContextDisableItem.Header = '禁用'
$script:TaskContextEnableItem = New-Object Windows.Controls.MenuItem
$script:TaskContextEnableItem.Header = '启用'
$taskContextSeparator = New-Object Windows.Controls.Separator
$script:TaskContextExportItem = New-Object Windows.Controls.MenuItem
$script:TaskContextExportItem.Header = '导出'
$script:TaskContextDeleteItem = New-Object Windows.Controls.MenuItem
$script:TaskContextDeleteItem.Header = '删除'

[void]$script:TaskContextMenu.Items.Add($script:TaskContextRunItem)
[void]$script:TaskContextMenu.Items.Add($script:TaskContextStopItem)
[void]$script:TaskContextMenu.Items.Add($script:TaskContextDisableItem)
[void]$script:TaskContextMenu.Items.Add($script:TaskContextEnableItem)
[void]$script:TaskContextMenu.Items.Add($taskContextSeparator)
[void]$script:TaskContextMenu.Items.Add($script:TaskContextExportItem)
[void]$script:TaskContextMenu.Items.Add($script:TaskContextDeleteItem)
$script:TaskGrid.ContextMenu = $script:TaskContextMenu

$script:TaskContextRunItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'RunButton' })
$script:TaskContextStopItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'StopButton' })
$script:TaskContextDisableItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'DisableButton' })
$script:TaskContextEnableItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'EnableButton' })
$script:TaskContextExportItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'ExportXmlButton' })
$script:TaskContextDeleteItem.Add_Click({ Invoke-MainToolbarAction -ButtonName 'DeleteButton' })

$script:TaskGrid.Add_PreviewMouseRightButtonDown({
    param($sender, $eventArgs)

    $element = $eventArgs.OriginalSource
    while ($null -ne $element -and -not ($element -is [Windows.Controls.DataGridRow])) {
        if (-not ($element -is [Windows.DependencyObject])) {
            $element = $null
            break
        }
        $element = [Windows.Media.VisualTreeHelper]::GetParent($element)
    }
    if ($element -is [Windows.Controls.DataGridRow]) {
        $script:TaskGrid.SelectedItem = $element.Item
        $element.IsSelected = $true
        [void]$element.Focus()
    }
    else {
        $script:TaskGrid.SelectedItem = $null
    }
})
$script:TaskGrid.Add_ContextMenuOpening({
    param($sender, $eventArgs)

    if ($script:IsBusy -or $null -eq $script:TaskGrid.SelectedItem) {
        $eventArgs.Handled = $true
        return
    }
    Update-TaskContextMenu -TaskModel $script:TaskGrid.SelectedItem
})

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
        if ([int]$task.State -eq 4) {
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
            if ($null -ne $runtimeInfo) {
                $task.Stop(0)
                Write-AppLog -Message ('禁用前已停止运行中的后台应用：{0}' -f $model.Path)
            }
        }
        $task.Enabled = $false
    }
})

$script:MainWindow.FindName('DeleteButton').Add_Click({
    try {
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
    }
    catch {
        $message = Get-FriendlyError -ErrorRecord $_ -Context '打开删除确认窗口'
        Show-ErrorMessage $message
        Set-Status -Text $message
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
        Write-Output ('SMOKE OK: STA={0}; Folders={1}; RootTasks={2}; SkippedFolders={3}; Icon={4}' -f
            [Threading.Thread]::CurrentThread.ApartmentState,
            $script:FolderPaths.Count,
            $smokeModels.Count,
            $smokeErrors.Count,
            $script:MainIconLoaded)
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
