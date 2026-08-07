function Show-TaskEditor {
    param(
        [ValidateSet('Create', 'Edit')][string]$Mode,
        $ExistingData
    )

    [xml]$editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="任务" Width="780" MinWidth="700" MinHeight="450" MaxHeight="950"
        SizeToContent="Height" WindowStartupLocation="CenterOwner" ResizeMode="CanResize">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="840">
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
        <StackPanel Grid.Row="6" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,0,0,4">
          <Label Content="操作" Margin="0,0,8,0"/>
          <Button x:Name="AddActionButton" Width="85" Content="添加操作"/>
        </StackPanel>
        <ScrollViewer Grid.Row="7" Grid.Column="0" Grid.ColumnSpan="2" MaxHeight="250"
                      VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="ActionsPanel"/>
        </ScrollViewer>
        <Separator Grid.Row="8" Grid.ColumnSpan="2" Margin="0,10"/>
        <Label Grid.Row="9" Grid.Column="0" Content="运行方式"/>
        <CheckBox x:Name="BackgroundBox" Grid.Row="9" Grid.Column="1" Margin="8,7"
                  Content="后台应用（无控制台窗口，记录 stdout/stderr）"/>
        <TextBlock Grid.Row="10" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666" TextWrapping="Wrap"
                   Text="后台模式应用于第一个 Exec 操作。运行文件按完整任务路径的 SHA-256 隔离。"/>
        <Label Grid.Row="11" Grid.Column="0" Content="日志目录（可选）"/>
        <Grid Grid.Row="11" Grid.Column="1">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBox x:Name="LogDirectoryBox" Margin="4" ToolTip="仅用于后台应用；留空使用任务专属默认目录"
                   IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
          <Button x:Name="BrowseLogDirectoryButton" Grid.Column="1" Width="75" Margin="4" Content="浏览..."
                  IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
        </Grid>
        <TextBlock Grid.Row="12" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666" TextWrapping="Wrap"
                   Text="仅用于后台应用。留空时日志保存在任务专属目录的 logs 子目录。"/>
        <Separator Grid.Row="13" Grid.ColumnSpan="2" Margin="0,10"/>
        <Label Grid.Row="14" Grid.Column="0" Content="自定义环境变量"
               IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}"/>
        <Grid Grid.Row="14" Grid.Column="1" Margin="4,0"
              IsEnabled="{Binding IsChecked, ElementName=BackgroundBox}">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>
          <ScrollViewer MaxHeight="120" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="EnvVarsPanel"/>
          </ScrollViewer>
          <Button x:Name="AddEnvVarButton" Grid.Row="1" Width="85" Margin="0,4,0,0"
                  HorizontalAlignment="Left" Content="添加变量"/>
        </Grid>
        <TextBlock Grid.Row="15" Grid.Column="1" Margin="8,0,4,5" Foreground="#666666"
                   TextWrapping="Wrap"
                   Text="仅用于后台应用。变量名不能为空；值为空则取消该变量。同名变量将覆盖继承值。"/>
        <Separator Grid.Row="16" Grid.ColumnSpan="2" Margin="0,10"/>
        <StackPanel Grid.Row="17" Grid.Column="0" Grid.ColumnSpan="2" Orientation="Horizontal" Margin="0,0,0,4">
          <Label Content="触发器" Margin="0,0,8,0"/>
          <Button x:Name="AddTriggerButton" Width="85" Content="添加触发器"/>
        </StackPanel>
        <ScrollViewer Grid.Row="18" Grid.Column="0" Grid.ColumnSpan="2" MaxHeight="300"
                      VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="TriggersPanel"/>
        </ScrollViewer>
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
    try {
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
    $window.Owner = $script:MainWindow
    $window.Title = if ($Mode -eq 'Create') { '创建任务' } else { '编辑任务' }

    $taskPathBox = $window.FindName('TaskPathBox')
    $taskNameBox = $window.FindName('TaskNameBox')
    $descriptionBox = $window.FindName('DescriptionBox')
    $enabledBox = $window.FindName('EnabledBox')
    $backgroundBox = $window.FindName('BackgroundBox')
    $logDirectoryBox = $window.FindName('LogDirectoryBox')
    $actionsPanel = $window.FindName('ActionsPanel')
    $addActionButton = $window.FindName('AddActionButton')
    $triggersPanel = $window.FindName('TriggersPanel')
    $addTriggerButton = $window.FindName('AddTriggerButton')
    $browseLogDirectoryButton = $window.FindName('BrowseLogDirectoryButton')
    $saveButton = $window.FindName('SaveButton')
    $cancelButton = $window.FindName('CancelButton')
    $envVarsPanel = $window.FindName('EnvVarsPanel')
    $addEnvVarButton = $window.FindName('AddEnvVarButton')

    $script:__envVarRows = New-Object 'System.Collections.Generic.List[object]'
    $script:__envVarsPanel = $envVarsPanel
    $script:__actionRows = New-Object 'System.Collections.Generic.List[object]'
    $script:__triggerRows = New-Object 'System.Collections.Generic.List[object]'
    $script:__actionsPanel = $actionsPanel
    $script:__triggersPanel = $triggersPanel

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
        $removeButton.Width = 26; $removeButton.Height = 22
        $removeButton.Margin = [Windows.Thickness]::new(4, 2, 0, 2)
        $removeButton.FontSize = 11; $removeButton.Tag = $row
        [Windows.Controls.Grid]::SetColumn($removeButton, 3)
        $removeButton.Add_Click({
            $currentRow = $this.Tag
            [void]$script:__envVarsPanel.Children.Remove($currentRow)
            [void]$script:__envVarRows.Remove($currentRow)
        })
        [void]$row.Children.Add($removeButton)
        $row.Margin = [Windows.Thickness]::new(0, 0, 0, 2)
        [void]$script:__envVarsPanel.Children.Add($row)
        [void]$script:__envVarRows.Add($row)
        return @{ NameBox = $nameBox; ValueBox = $valueBox }
    }

    function New-ActionRow {
        $outerBorder = New-Object Windows.Controls.Border
        $outerBorder.BorderBrush = [Windows.Media.Brushes]::LightGray
        $outerBorder.BorderThickness = [Windows.Thickness]::new(1)
        $outerBorder.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
        $outerBorder.Padding = [Windows.Thickness]::new(6)
        $grid = New-Object Windows.Controls.Grid
        for ($i = 0; $i -lt 6; $i++) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'
            [void]$grid.RowDefinitions.Add($rd)
        }
        $colA = New-Object Windows.Controls.ColumnDefinition
        $colA.Width = [Windows.GridLength]::new(65)
        $colB = New-Object Windows.Controls.ColumnDefinition
        $colB.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $colC = New-Object Windows.Controls.ColumnDefinition
        $colC.Width = [Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($colA); [void]$grid.ColumnDefinitions.Add($colB); [void]$grid.ColumnDefinitions.Add($colC)

        # Row 0: type combo + remove button
        $typeCombo = New-Object Windows.Controls.ComboBox
        $typeCombo.Margin = [Windows.Thickness]::new(2)
        $itemExec = New-Object Windows.Controls.ComboBoxItem; $itemExec.Content = 'Exec 程序'
        [void]$typeCombo.Items.Add($itemExec)
        $typeCombo.SelectedIndex = 0
        $typeCombo.IsEnabled = $false
        [Windows.Controls.Grid]::SetRow($typeCombo, 0); [Windows.Controls.Grid]::SetColumn($typeCombo, 1)
        [void]$grid.Children.Add($typeCombo)

        $removeBtn = New-Object Windows.Controls.Button
        $removeBtn.Content = '删除此操作'; $removeBtn.Width = 85; $removeBtn.Height = 22
        $removeBtn.Margin = [Windows.Thickness]::new(4, 2, 0, 2); $removeBtn.FontSize = 11
        [Windows.Controls.Grid]::SetRow($removeBtn, 0); [Windows.Controls.Grid]::SetColumn($removeBtn, 2)
        [void]$grid.Children.Add($removeBtn)

        # Row 1: Exec - program path + browse
        $execPathLabel = New-Object Windows.Controls.TextBlock
        $execPathLabel.Text = '程序路径'; $execPathLabel.Margin = [Windows.Thickness]::new(2, 4, 4, 2)
        $execPathLabel.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetRow($execPathLabel, 1); [Windows.Controls.Grid]::SetColumn($execPathLabel, 0)
        [void]$grid.Children.Add($execPathLabel)

        $execPathBox = New-Object Windows.Controls.TextBox
        $execPathBox.Margin = [Windows.Thickness]::new(2, 2, 2, 2)
        [Windows.Controls.Grid]::SetRow($execPathBox, 1); [Windows.Controls.Grid]::SetColumn($execPathBox, 1)
        [void]$grid.Children.Add($execPathBox)

        $execBrowseBtn = New-Object Windows.Controls.Button
        $execBrowseBtn.Content = '浏览...'; $execBrowseBtn.Width = 75; $execBrowseBtn.Height = 22
        $execBrowseBtn.Margin = [Windows.Thickness]::new(4, 2, 2, 2)
        [Windows.Controls.Grid]::SetRow($execBrowseBtn, 1); [Windows.Controls.Grid]::SetColumn($execBrowseBtn, 2)
        [void]$grid.Children.Add($execBrowseBtn)

        # Row 2: Exec - arguments
        $execArgsLabel = New-Object Windows.Controls.TextBlock
        $execArgsLabel.Text = '参数'; $execArgsLabel.Margin = [Windows.Thickness]::new(2, 2, 4, 2)
        $execArgsLabel.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetRow($execArgsLabel, 2); [Windows.Controls.Grid]::SetColumn($execArgsLabel, 0)
        [void]$grid.Children.Add($execArgsLabel)
        $execArgsBox = New-Object Windows.Controls.TextBox
        $execArgsBox.Margin = [Windows.Thickness]::new(2, 2, 2, 2)
        [Windows.Controls.Grid]::SetRow($execArgsBox, 2); [Windows.Controls.Grid]::SetColumn($execArgsBox, 1)
        [void]$grid.Children.Add($execArgsBox)

        # Row 3: Exec - working directory
        $execWdLabel = New-Object Windows.Controls.TextBlock
        $execWdLabel.Text = '工作目录'; $execWdLabel.Margin = [Windows.Thickness]::new(2, 2, 4, 2)
        $execWdLabel.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetRow($execWdLabel, 3); [Windows.Controls.Grid]::SetColumn($execWdLabel, 0)
        [void]$grid.Children.Add($execWdLabel)
        $execWdBox = New-Object Windows.Controls.TextBox
        $execWdBox.Margin = [Windows.Thickness]::new(2, 2, 2, 2)
        [Windows.Controls.Grid]::SetRow($execWdBox, 3); [Windows.Controls.Grid]::SetColumn($execWdBox, 1)
        [void]$grid.Children.Add($execWdBox)

        # ShowMessage fields
        $msgTitleLabel = New-Object Windows.Controls.TextBlock
        $msgTitleLabel.Text = '标题'; $msgTitleLabel.Margin = [Windows.Thickness]::new(2, 4, 4, 2)
        $msgTitleLabel.VerticalAlignment = 'Center'; $msgTitleLabel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($msgTitleLabel, 1); [Windows.Controls.Grid]::SetColumn($msgTitleLabel, 0)
        [void]$grid.Children.Add($msgTitleLabel)
        $msgTitleBox = New-Object Windows.Controls.TextBox
        $msgTitleBox.Margin = [Windows.Thickness]::new(2, 2, 2, 2); $msgTitleBox.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($msgTitleBox, 1); [Windows.Controls.Grid]::SetColumn($msgTitleBox, 1)
        [void]$grid.Children.Add($msgTitleBox)

        $msgBodyLabel = New-Object Windows.Controls.TextBlock
        $msgBodyLabel.Text = '消息正文'; $msgBodyLabel.Margin = [Windows.Thickness]::new(2, 2, 4, 2)
        $msgBodyLabel.VerticalAlignment = 'Center'; $msgBodyLabel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($msgBodyLabel, 2); [Windows.Controls.Grid]::SetColumn($msgBodyLabel, 0)
        [void]$grid.Children.Add($msgBodyLabel)
        $msgBodyBox = New-Object Windows.Controls.TextBox
        $msgBodyBox.Margin = [Windows.Thickness]::new(2, 2, 2, 2); $msgBodyBox.Visibility = 'Collapsed'
        $msgBodyBox.Height = 50; $msgBodyBox.AcceptsReturn = $true; $msgBodyBox.TextWrapping = 'Wrap'
        [Windows.Controls.Grid]::SetRow($msgBodyBox, 2); [Windows.Controls.Grid]::SetColumn($msgBodyBox, 1)
        [void]$grid.Children.Add($msgBodyBox)

        # Wire browse button after all text boxes exist.
        $execBrowseBtn.Tag = [PSCustomObject]@{ PathBox = $execPathBox; WdBox = $execWdBox }
        $execBrowseBtn.Add_Click({
            try {
                $data = $this.Tag
                $dialog = New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Title = '选择要运行的程序'
                $dialog.Filter = '可执行文件 (*.exe;*.com;*.bat;*.cmd)|*.exe;*.com;*.bat;*.cmd|所有文件 (*.*)|*.*'
                if ($dialog.ShowDialog($window)) {
                    $data.PathBox.Text = $dialog.FileName
                    if ([string]::IsNullOrWhiteSpace($data.WdBox.Text)) {
                        $data.WdBox.Text = [IO.Path]::GetDirectoryName($dialog.FileName)
                    }
                }
            }
            catch {
                [void][Windows.MessageBox]::Show(
                    $window, $_.Exception.Message,
                    '浏览文件失败',
                    [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning
                )
            }
            finally {
                if ($null -ne $dialog) { $dialog.Dispose() }
            }
        })

        # Exec field list for toggling — stored on combo for event handler access.
        $typeCombo.Tag = [PSCustomObject]@{ ExecFields = @($execPathLabel, $execPathBox, $execBrowseBtn, $execArgsLabel, $execArgsBox, $execWdLabel, $execWdBox); MsgFields = @($msgTitleLabel, $msgTitleBox, $msgBodyLabel, $msgBodyBox) }

        $typeCombo.Add_SelectionChanged({
            # Only Exec is supported; ShowMessage is a deprecated feature that
            # the Task Scheduler service rejects on modern Windows.
        })

        $removeBtn.Tag = $outerBorder
        $removeBtn.Add_Click({
            $target = $this.Tag
            [void]$script:__actionRows.Remove($target)
            [void]$script:__actionsPanel.Children.Remove($target)
        })

        $outerBorder.Tag = [PSCustomObject]@{
            Grid = $grid
            ExecPathBox = $execPathBox
            ExecArgsBox = $execArgsBox
            ExecWdBox = $execWdBox
        }
        $outerBorder.Child = $grid
        [void]$actionsPanel.Children.Add($outerBorder)
        [void]$script:__actionRows.Add($outerBorder)
        return @{
            TypeCombo = $typeCombo
            ExecPathBox = $execPathBox; ExecArgsBox = $execArgsBox; ExecWdBox = $execWdBox
            MsgTitleBox = $msgTitleBox; MsgBodyBox = $msgBodyBox
        }
    }

    function New-TriggerRow {
        $outerBorder = New-Object Windows.Controls.Border
        $outerBorder.BorderBrush = [Windows.Media.Brushes]::LightGray
        $outerBorder.BorderThickness = [Windows.Thickness]::new(1)
        $outerBorder.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
        $outerBorder.Padding = [Windows.Thickness]::new(6)
        $grid = New-Object Windows.Controls.Grid
        for ($i = 0; $i -lt 10; $i++) {
            $rd = New-Object Windows.Controls.RowDefinition; $rd.Height = 'Auto'
            [void]$grid.RowDefinitions.Add($rd)
        }
        $colA = New-Object Windows.Controls.ColumnDefinition
        $colA.Width = [Windows.GridLength]::new(85)
        $colB = New-Object Windows.Controls.ColumnDefinition
        $colB.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
        $colC = New-Object Windows.Controls.ColumnDefinition
        $colC.Width = [Windows.GridLength]::Auto
        [void]$grid.ColumnDefinitions.Add($colA); [void]$grid.ColumnDefinitions.Add($colB); [void]$grid.ColumnDefinitions.Add($colC)

        # Row 0 & 1: type combo + remove + StartBoundary + repeat
        # Row 0: type combo
        $typeCombo = New-Object Windows.Controls.ComboBox
        $typeCombo.Margin = [Windows.Thickness]::new(2)
        $triggerKinds = @('登录时', '单次', '每天', '每周', '每月', '每月（星期）', '空闲时', '注册时')
        foreach ($tk in $triggerKinds) {
            $item = New-Object Windows.Controls.ComboBoxItem; $item.Content = $tk
            [void]$typeCombo.Items.Add($item)
        }
        $typeCombo.SelectedIndex = 1
        [Windows.Controls.Grid]::SetRow($typeCombo, 0); [Windows.Controls.Grid]::SetColumn($typeCombo, 1)
        [void]$grid.Children.Add($typeCombo)

        $removeBtn = New-Object Windows.Controls.Button
        $removeBtn.Content = '删除此触发器'; $removeBtn.Width = 100; $removeBtn.Height = 22
        $removeBtn.Margin = [Windows.Thickness]::new(4, 2, 0, 2); $removeBtn.FontSize = 11
        [Windows.Controls.Grid]::SetRow($removeBtn, 0); [Windows.Controls.Grid]::SetColumn($removeBtn, 2)
        [void]$grid.Children.Add($removeBtn)

        # Row 1: Start date + time (time-based only)
        $dateTimePanel = New-Object Windows.Controls.StackPanel
        $dateTimePanel.Orientation = 'Horizontal'; $dateTimePanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2)
        [Windows.Controls.Grid]::SetRow($dateTimePanel, 1); [Windows.Controls.Grid]::SetColumn($dateTimePanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($dateTimePanel, 2)
        [void]$grid.Children.Add($dateTimePanel)
        $startDatePicker = New-Object Windows.Controls.DatePicker
        $startDatePicker.Width = 180; $startDatePicker.Margin = [Windows.Thickness]::new(0, 0, 8, 0)
        [void]$dateTimePanel.Children.Add($startDatePicker)
        $startTimeBox = New-Object Windows.Controls.TextBox
        $startTimeBox.Width = 80; $startTimeBox.Margin = [Windows.Thickness]::new(0, 0, 8, 0); $startTimeBox.ToolTip = 'HH:mm'
        [void]$dateTimePanel.Children.Add($startTimeBox)
        $dateTimeHint = New-Object Windows.Controls.TextBlock
        $dateTimeHint.Text = '（登录、空闲、注册触发器忽略此项）'
        $dateTimeHint.VerticalAlignment = 'Center'; $dateTimeHint.Foreground = '#666666'
        [void]$dateTimePanel.Children.Add($dateTimeHint)

        # Row 2: Repeat + RandomDelay
        $repeatPanel = New-Object Windows.Controls.StackPanel
        $repeatPanel.Orientation = 'Horizontal'; $repeatPanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2)
        [Windows.Controls.Grid]::SetRow($repeatPanel, 2); [Windows.Controls.Grid]::SetColumn($repeatPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($repeatPanel, 2)
        [void]$grid.Children.Add($repeatPanel)
        $repeatLabel = New-Object Windows.Controls.TextBlock
        $repeatLabel.Text = '重复间隔(分钟)'; $repeatLabel.VerticalAlignment = 'Center'; $repeatLabel.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        [void]$repeatPanel.Children.Add($repeatLabel)
        $repeatMinsBox = New-Object Windows.Controls.TextBox
        $repeatMinsBox.Width = 60; $repeatMinsBox.Margin = [Windows.Thickness]::new(0, 0, 8, 0); $repeatMinsBox.Text = '0'
        [void]$repeatPanel.Children.Add($repeatMinsBox)
        $randomLabel = New-Object Windows.Controls.TextBlock
        $randomLabel.Text = '随机延迟(ISO)'; $randomLabel.VerticalAlignment = 'Center'; $randomLabel.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        [void]$repeatPanel.Children.Add($randomLabel)
        $randomDelayBox = New-Object Windows.Controls.TextBox
        $randomDelayBox.Width = 90; $randomDelayBox.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        $randomDelayBox.ToolTip = '例如 PT30M，留空表示不随机延迟'
        [void]$repeatPanel.Children.Add($randomDelayBox)
        $repeatHint = New-Object Windows.Controls.TextBlock
        $repeatHint.Text = '0 表示不重复'; $repeatHint.VerticalAlignment = 'Center'; $repeatHint.Foreground = '#666666'
        [void]$repeatPanel.Children.Add($repeatHint)

        # Row 3: Weekly fields (DaysOfWeek + WeeksInterval)
        $weeklyPanel = New-Object Windows.Controls.WrapPanel
        $weeklyPanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2); $weeklyPanel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($weeklyPanel, 3); [Windows.Controls.Grid]::SetColumn($weeklyPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($weeklyPanel, 2)
        [void]$grid.Children.Add($weeklyPanel)
        $dowTogglesForWeekly = @()
        for ($di = 0; $di -lt 7; $di++) {
            $tb = New-Object Windows.Controls.Primitives.ToggleButton
            $tb.Content = $script:DayOfWeekShortNames[$di]; $tb.Width = 28; $tb.Height = 22
            $tb.Margin = [Windows.Thickness]::new(1); $tb.FontSize = 11; $tb.Padding = [Windows.Thickness]::new(0)
            $tb.Tag = $script:DayOfWeekMasks[$di]
            [void]$weeklyPanel.Children.Add($tb)
            $dowTogglesForWeekly += $tb
        }
        $weeksLabelW = New-Object Windows.Controls.TextBlock
        $weeksLabelW.Text = '  间隔周数'; $weeksLabelW.VerticalAlignment = 'Center'; $weeksLabelW.Margin = [Windows.Thickness]::new(8, 0, 4, 0)
        [void]$weeklyPanel.Children.Add($weeksLabelW)
        $weeksIntervalBox = New-Object Windows.Controls.TextBox
        $weeksIntervalBox.Width = 40; $weeksIntervalBox.Text = '1'
        [void]$weeklyPanel.Children.Add($weeksIntervalBox)

        # Row 4: Monthly fields (DaysOfMonth text + Months)
        $monthlyPanel = New-Object Windows.Controls.StackPanel
        $monthlyPanel.Orientation = 'Horizontal'; $monthlyPanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2)
        $monthlyPanel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($monthlyPanel, 4); [Windows.Controls.Grid]::SetColumn($monthlyPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($monthlyPanel, 2)
        [void]$grid.Children.Add($monthlyPanel)
        $domLabel = New-Object Windows.Controls.TextBlock
        $domLabel.Text = '天号(逗号分隔 1-31)'; $domLabel.VerticalAlignment = 'Center'; $domLabel.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        [void]$monthlyPanel.Children.Add($domLabel)
        $domBox = New-Object Windows.Controls.TextBox
        $domBox.Width = 140; $domBox.Margin = [Windows.Thickness]::new(0, 0, 8, 0); $domBox.ToolTip = '例如 1,15,28'
        [void]$monthlyPanel.Children.Add($domBox)

        # Row 5: Months toggle (shared by Monthly and MonthlyDOW)
        $monthsPanel = New-Object Windows.Controls.WrapPanel
        $monthsPanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2); $monthsPanel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($monthsPanel, 5); [Windows.Controls.Grid]::SetColumn($monthsPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($monthsPanel, 2)
        [void]$grid.Children.Add($monthsPanel)
        $monthToggles = @()
        for ($mi = 0; $mi -lt 12; $mi++) {
            $mt = New-Object Windows.Controls.Primitives.ToggleButton
            $mt.Content = [string]($mi + 1) + '月'; $mt.Width = 32; $mt.Height = 22
            $mt.Margin = [Windows.Thickness]::new(1); $mt.FontSize = 11; $mt.Padding = [Windows.Thickness]::new(0)
            $mt.Tag = $script:MonthMasks[$mi]
            [void]$monthsPanel.Children.Add($mt)
            $monthToggles += $mt
        }

        # Row 6: MonthlyDOW fields (DOW + WeeksOfMonth)
        $monthlyDowPanel = New-Object Windows.Controls.WrapPanel
        $monthlyDowPanel.Margin = [Windows.Thickness]::new(2, 2, 0, 2); $monthlyDowPanel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($monthlyDowPanel, 6); [Windows.Controls.Grid]::SetColumn($monthlyDowPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($monthlyDowPanel, 2)
        [void]$grid.Children.Add($monthlyDowPanel)
        $dowTogglesForMDOW = @()
        for ($di = 0; $di -lt 7; $di++) {
            $tb = New-Object Windows.Controls.Primitives.ToggleButton
            $tb.Content = $script:DayOfWeekShortNames[$di]; $tb.Width = 28; $tb.Height = 22
            $tb.Margin = [Windows.Thickness]::new(1); $tb.FontSize = 11; $tb.Padding = [Windows.Thickness]::new(0)
            $tb.Tag = $script:DayOfWeekMasks[$di]
            [void]$monthlyDowPanel.Children.Add($tb)
            $dowTogglesForMDOW += $tb
        }
        $womToggles = @()
        for ($wi = 0; $wi -lt 5; $wi++) {
            $wt = New-Object Windows.Controls.Primitives.ToggleButton
            $wt.Content = $script:WeekOfMonthNames[$wi]; $wt.Height = 22
            $wt.Margin = [Windows.Thickness]::new(1); $wt.FontSize = 11; $wt.Padding = [Windows.Thickness]::new(2, 0, 2, 0)
            $wt.Tag = $script:WeekOfMonthMasks[$wi]
            [void]$monthlyDowPanel.Children.Add($wt)
            $womToggles += $wt
        }

        # Row 7: Registration delay
        $regDelayPanel = New-Object Windows.Controls.StackPanel
        $regDelayPanel.Orientation = 'Horizontal'; $regDelayPanel.Margin = [Windows.Thickness]::new(2, 4, 0, 2)
        $regDelayPanel.Visibility = 'Collapsed'
        [Windows.Controls.Grid]::SetRow($regDelayPanel, 7); [Windows.Controls.Grid]::SetColumn($regDelayPanel, 1)
        [Windows.Controls.Grid]::SetColumnSpan($regDelayPanel, 2)
        [void]$grid.Children.Add($regDelayPanel)
        $regDelayLabel = New-Object Windows.Controls.TextBlock
        $regDelayLabel.Text = '延迟(ISO)'; $regDelayLabel.VerticalAlignment = 'Center'; $regDelayLabel.Margin = [Windows.Thickness]::new(0, 0, 4, 0)
        [void]$regDelayPanel.Children.Add($regDelayLabel)
        $regDelayBox = New-Object Windows.Controls.TextBox
        $regDelayBox.Width = 100; $regDelayBox.ToolTip = '例如 PT30S，留空表示不延迟'
        [void]$regDelayPanel.Children.Add($regDelayBox)

        # Visibility groups — stored on combo for event handler access.
        $typeCombo.Tag = [PSCustomObject]@{
            TimeBasedFields = @($dateTimePanel, $repeatPanel)
            AllTypeSpecific = @($weeklyPanel, $monthlyPanel, $monthsPanel, $monthlyDowPanel, $regDelayPanel)
            WeeklyFields = @($weeklyPanel)
            MonthlyFields = @($monthlyPanel, $monthsPanel)
            MonthlyDowFields = @($monthlyDowPanel, $monthsPanel)
            RegFields = @($regDelayPanel)
        }

        $typeCombo.Add_SelectionChanged({
            $data = $this.Tag
            $kind = [string]$this.SelectedItem.Content
            $isTimeBased = $kind -in @('单次', '每天', '每周', '每月', '每月（星期）')
            $vis = if ($isTimeBased) { 'Visible' } else { 'Collapsed' }
            foreach ($c in $data.TimeBasedFields) { $c.Visibility = $vis }
            foreach ($c in $data.AllTypeSpecific) { $c.Visibility = 'Collapsed' }
            switch ($kind) {
                '每周' { foreach ($c in $data.WeeklyFields) { $c.Visibility = 'Visible' } }
                '每月' { foreach ($c in $data.MonthlyFields) { $c.Visibility = 'Visible' } }
                '每月（星期）' { foreach ($c in $data.MonthlyDowFields) { $c.Visibility = 'Visible' } }
                '注册时' { foreach ($c in $data.RegFields) { $c.Visibility = 'Visible' } }
            }
        })

        $removeBtn.Tag = $outerBorder
        $removeBtn.Add_Click({
            $target = $this.Tag
            [void]$script:__triggerRows.Remove($target)
            [void]$script:__triggersPanel.Children.Remove($target)
        })

        $outerBorder.Tag = [PSCustomObject]@{
            Grid = $grid
            TypeCombo = $typeCombo
            StartDatePicker = $startDatePicker
            StartTimeBox = $startTimeBox
            RepeatMinsBox = $repeatMinsBox
            RandomDelayBox = $randomDelayBox
            DowToggles = $dowTogglesForWeekly
            WeeksIntervalBox = $weeksIntervalBox
            DomBox = $domBox
            MonthToggles = $monthToggles
            MonthlyDowDOWToggles = $dowTogglesForMDOW
            WomToggles = $womToggles
            RegDelayBox = $regDelayBox
        }
        $outerBorder.Child = $grid
        [void]$triggersPanel.Children.Add($outerBorder)
        [void]$script:__triggerRows.Add($outerBorder)
        return @{
            TypeCombo = $typeCombo
            StartDatePicker = $startDatePicker; StartTimeBox = $startTimeBox
            RepeatMinsBox = $repeatMinsBox; RandomDelayBox = $randomDelayBox
            DowToggles = $dowTogglesForWeekly; WeeksIntervalBox = $weeksIntervalBox
            DomBox = $domBox; MonthToggles = $monthToggles
            MonthlyDowDOWToggles = $dowTogglesForMDOW; WomToggles = $womToggles
            RegDelayBox = $regDelayBox
        }
    }

    $addEnvVarButton.Add_Click({ [void](New-EnvVarRow) })

    foreach ($path in $script:FolderPaths) {
        [void]$taskPathBox.Items.Add($path)
    }

    if ($Mode -eq 'Edit') {
        $taskPathBox.Text = $ExistingData.TaskPath
        $taskNameBox.Text = $ExistingData.TaskName
        $descriptionBox.Text = $ExistingData.Description
        $enabledBox.IsChecked = $ExistingData.Enabled
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
        # Populate actions from edit data.
        if ($null -ne $ExistingData.PSObject.Properties['Actions'] -and $ExistingData.Actions.Count -gt 0) {
            foreach ($actData in $ExistingData.Actions) {
                $ar = New-ActionRow
                $ar.ExecPathBox.Text = $actData.Program
                $ar.ExecArgsBox.Text = $actData.Arguments
                $ar.ExecWdBox.Text = $actData.WorkingDirectory
            }
        }
        # Populate triggers from edit data.
        if ($null -ne $ExistingData.PSObject.Properties['Triggers'] -and $ExistingData.Triggers.Count -gt 0) {
            foreach ($trgData in $ExistingData.Triggers) {
                $tr = New-TriggerRow
                for ($ti = 0; $ti -lt $tr.TypeCombo.Items.Count; $ti++) {
                    if ([string]$tr.TypeCombo.Items[$ti].Content -eq $trgData.Kind) {
                        $tr.TypeCombo.SelectedIndex = $ti; break
                    }
                }
                $tr.StartDatePicker.SelectedDate = $trgData.StartDate
                $tr.StartTimeBox.Text = $trgData.StartTime
                $tr.RepeatMinsBox.Text = [string]$trgData.RepeatMinutes
                $tr.RandomDelayBox.Text = $trgData.RandomDelay
                if ($trgData.Kind -in @('每周', '每月（星期）')) {
                    $toggles = if ($trgData.Kind -eq '每周') { $tr.DowToggles } else { $tr.MonthlyDowDOWToggles }
                    foreach ($tb in $toggles) { $tb.IsChecked = ([int]$trgData.DaysOfWeek -band [int]$tb.Tag) -ne 0 }
                }
                if ($trgData.Kind -eq '每周') { $tr.WeeksIntervalBox.Text = [string]$trgData.WeeksInterval }
                if ($trgData.Kind -eq '每月') { $tr.DomBox.Text = (Convert-BitmaskToString -Mask ([int]$trgData.DaysOfMonth) -Names ([string[]](1..31 | ForEach-Object { [string]$_ })) -Values ([int[]](1..31 | ForEach-Object { [Math]::Pow(2, $_ - 1) }))) }
                if ($trgData.Kind -in @('每月', '每月（星期）')) {
                    foreach ($mt in $tr.MonthToggles) { $mt.IsChecked = ([int]$trgData.MonthsOfYear -band [int]$mt.Tag) -ne 0 }
                }
                if ($trgData.Kind -eq '每月（星期）') {
                    foreach ($wt in $tr.WomToggles) { $wt.IsChecked = ([int]$trgData.WeeksOfMonth -band [int]$wt.Tag) -ne 0 }
                }
                if ($trgData.Kind -eq '注册时') { $tr.RegDelayBox.Text = $trgData.Delay }
            }
        }
    }
    else {
        $taskPathBox.Text = $script:CurrentFolderPath
        $newAction = New-ActionRow
        $newTrigger = New-TriggerRow
        $newTrigger.StartDatePicker.SelectedDate = (Get-Date).Date.AddDays(1)
        $newTrigger.StartTimeBox.Text = '09:00'
        $newTrigger.RepeatMinsBox.Text = '0'
    }

    $addActionButton.Add_Click({ [void](New-ActionRow) })
    $addTriggerButton.Add_Click({
        $tr = New-TriggerRow
        $tr.StartDatePicker.SelectedDate = (Get-Date).Date.AddDays(1)
        $tr.StartTimeBox.Text = '09:00'
        $tr.RepeatMinsBox.Text = '0'
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
                $window, $_.Exception.Message,
                '无法选择日志目录',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning
            )
        }
        finally { if ($null -ne $dialog) { $dialog.Dispose() } }
    })

    $cancelButton.Add_Click({ $window.DialogResult = $false })
    $saveButton.Add_Click({
        try {
            $taskNameError = Test-TaskName $taskNameBox.Text
            if ($null -ne $taskNameError) { throw $taskNameError }
            $pathError = Test-FolderPath $taskPathBox.Text
            if ($null -ne $pathError) { throw $pathError }

            # --- Extract actions ---
            $actionList = New-Object 'System.Collections.Generic.List[object]'
            foreach ($row in $script:__actionRows) {
                $tag = $row.Tag
                $execPathBox = $tag.ExecPathBox; $execArgsBox = $tag.ExecArgsBox; $execWdBox = $tag.ExecWdBox
                $prog = [string]$execPathBox.Text
                if ([string]::IsNullOrWhiteSpace($prog)) { throw '程序路径不能为空。' }
                if ($prog.IndexOf([char]0) -ge 0) { throw '程序路径包含无效字符。' }
                $args = [string]$execArgsBox.Text
                if ($args.IndexOf([char]0) -ge 0) { throw '参数包含无效字符。' }
                $wd = [string]$execWdBox.Text
                if ($wd.IndexOf([char]0) -ge 0) { throw '工作目录包含无效字符。' }
                [void]$actionList.Add([PSCustomObject]@{ Type='Exec'; Program=$prog; Arguments=$args; WorkingDirectory=$wd; Title=''; MessageBody='' })
            }
            if ($actionList.Count -eq 0) { throw '请至少添加一个操作。' }
            $firstAction = $actionList[0]

            # --- Extract triggers ---
            $triggerList = New-Object 'System.Collections.Generic.List[object]'
            foreach ($row in $script:__triggerRows) {
                $tag = $row.Tag
                $kind = [string]$tag.TypeCombo.SelectedItem.Content
                $startDatePicker = $tag.StartDatePicker
                $startTimeBox = $tag.StartTimeBox
                $repeatMinsBox = $tag.RepeatMinsBox
                $randomDelayBox = $tag.RandomDelayBox

                $trgStartDate = $startDatePicker.SelectedDate
                $trgStartTime = $startTimeBox.Text.Trim()
                $trgStartDt = Get-Date

                if ($kind -in @('单次', '每天', '每周', '每月', '每月（星期）')) {
                    if ($null -eq $trgStartDate) { throw ('触发器 "{0}"：请选择开始日期。' -f $kind) }
                    $parsedTime = [DateTime]::MinValue
                    if (-not [DateTime]::TryParseExact($trgStartTime, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedTime)) {
                        throw ('触发器 "{0}"：开始时间必须使用 HH:mm 格式。' -f $kind)
                    }
                    $trgStartDt = $trgStartDate.Date.Add($parsedTime.TimeOfDay)
                }

                $trgRepeatMins = 0
                if (-not [int]::TryParse($repeatMinsBox.Text.Trim(), [ref]$trgRepeatMins) -or $trgRepeatMins -lt 0 -or $trgRepeatMins -gt 44640) {
                    throw '重复间隔必须是 0 到 44640 之间的整数分钟数。'
                }
                if ($trgRepeatMins -gt 0 -and $kind -in @('登录时', '空闲时', '注册时')) {
                    throw ('触发器 "{0}" 不支持重复。' -f $kind)
                }

                $trgRandomDelay = $randomDelayBox.Text.Trim()
                if ($trgRandomDelay -and $trgRandomDelay -notmatch '^PT(\d+H)?(\d+M)?(\d+S)?$') {
                    throw '随机延迟必须是 ISO 8601 格式，例如 PT30M。'
                }

                # Type-specific
                $trgDaysOfWeek = 0; $trgWeeksInterval = 1
                $trgDaysOfMonth = 0; $trgMonthsOfYear = 0; $trgWeeksOfMonth = 0; $trgDelay = ''
                switch ($kind) {
                    '每周' {
                        foreach ($tb in $tag.DowToggles) { if ($tb.IsChecked) { $trgDaysOfWeek = $trgDaysOfWeek -bor [int]$tb.Tag } }
                        if ($trgDaysOfWeek -eq 0) { throw '每周触发器：请至少选择一个星期。' }
                        [int]::TryParse($tag.WeeksIntervalBox.Text.Trim(), [ref]$trgWeeksInterval) | Out-Null
                        if ($trgWeeksInterval -lt 1) { $trgWeeksInterval = 1 }
                    }
                    '每月' {
                        $domText = $tag.DomBox.Text.Trim()
                        if ($domText) {
                            foreach ($d in ($domText -split ',')) {
                                $dn = 0; if ([int]::TryParse($d.Trim(), [ref]$dn) -and $dn -ge 1 -and $dn -le 31) {
                                    $trgDaysOfMonth = $trgDaysOfMonth -bor [Math]::Pow(2, $dn - 1)
                                }
                            }
                        }
                        if ($trgDaysOfMonth -eq 0) { throw '每月触发器：请填写有效的天号（逗号分隔，1-31）。' }
                        foreach ($mt in $tag.MonthToggles) { if ($mt.IsChecked) { $trgMonthsOfYear = $trgMonthsOfYear -bor [int]$mt.Tag } }
                    }
                    '每月（星期）' {
                        foreach ($tb in $tag.MonthlyDowDOWToggles) { if ($tb.IsChecked) { $trgDaysOfWeek = $trgDaysOfWeek -bor [int]$tb.Tag } }
                        if ($trgDaysOfWeek -eq 0) { throw '每月（星期）触发器：请至少选择一个星期。' }
                        foreach ($wt in $tag.WomToggles) { if ($wt.IsChecked) { $trgWeeksOfMonth = $trgWeeksOfMonth -bor [int]$wt.Tag } }
                        if ($trgWeeksOfMonth -eq 0) { throw '每月（星期）触发器：请至少选择一周。' }
                        foreach ($mt in $tag.MonthToggles) { if ($mt.IsChecked) { $trgMonthsOfYear = $trgMonthsOfYear -bor [int]$mt.Tag } }
                    }
                    '注册时' {
                        $trgDelay = $tag.RegDelayBox.Text.Trim()
                        if ($trgDelay -and $trgDelay -notmatch '^PT(\d+H)?(\d+M)?(\d+S)?$') { throw '注册触发器延迟必须是 ISO 8601 格式。' }
                    }
                }

                [void]$triggerList.Add([PSCustomObject]@{
                    Kind = $kind; StartDate = $trgStartDt.Date; StartTime = $trgStartDt.ToString('HH:mm')
                    RepeatMinutes = $trgRepeatMins; RandomDelay = $trgRandomDelay
                    DaysOfWeek = $trgDaysOfWeek; WeeksInterval = $trgWeeksInterval
                    DaysOfMonth = $trgDaysOfMonth; MonthsOfYear = $trgMonthsOfYear
                    WeeksOfMonth = $trgWeeksOfMonth; Delay = $trgDelay
                })
            }
            if ($triggerList.Count -eq 0) { throw '请至少添加一个触发器。' }
            $firstTrigger = $triggerList[0]

            $normalizedPath = Resolve-FolderPath $taskPathBox.Text
            $name = $taskNameBox.Text
            $fullPath = Join-TaskFullPath $normalizedPath $name
            if ([bool]$backgroundBox.IsChecked) {
                $runtimeValues = Get-BackgroundActionValues $fullPath
                [void](Resolve-BackgroundLogDirectory -RequestedPath $logDirectoryBox.Text -DefaultPath $runtimeValues.DefaultLogDirectory)
            }
            $originalPath = if ($Mode -eq 'Edit') { [string]$ExistingData.FullPath } else { $null }
            $isSameTask = $Mode -eq 'Edit' -and $originalPath -eq $fullPath
            $exists = $false
            try { $exists = Test-TaskExists -FolderPath $normalizedPath -TaskName $name }
            catch { throw (Get-FriendlyError -ErrorRecord $_ -Context ('检查任务 {0}' -f $fullPath)) }

            $overwrite = $false
            if ($exists) {
                $prompt = if ($isSameTask) {
                    "即将编辑现有任务：`n`n完整 TaskPath + TaskName：$fullPath`n`n确认以表单中的定义覆盖该任务吗？"
                } elseif ($Mode -eq 'Edit') {
                    "即将编辑并移动或重命名现有任务：`n$originalPath`n`n目标位置已有任务：`n$fullPath`n`n继续将覆盖目标任务，并在成功后删除原任务。确认吗？"
                } else { "同名任务已经存在：`n`n完整 TaskPath + TaskName：$fullPath`n`n确认覆盖吗？" }
                $answer = [Windows.MessageBox]::Show($window, $prompt, '确认覆盖现有任务',
                    [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
                if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
                $overwrite = $true
            } elseif ($Mode -eq 'Edit') {
                $prompt = "即将把现有任务：`n$originalPath`n`n保存为：`n$fullPath`n`n保存成功后将删除原任务。确认继续吗？"
                $answer = [Windows.MessageBox]::Show($window, $prompt, '确认移动或重命名任务',
                    [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning, [Windows.MessageBoxResult]::No)
                if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
            }

            $envVars = @{}
            foreach ($row in $script:__envVarRows) {
                $nameBox = $row.Children[0]; $valueBox = $row.Children[2]
                $key = $nameBox.Text.Trim()
                if ([string]::IsNullOrEmpty($key)) { continue }
                $envVars[$key] = $valueBox.Text
            }

            $window.Tag = [PSCustomObject]@{
                TaskPath = $normalizedPath
                TaskName = $name
                Description = [string]$descriptionBox.Text
                Enabled = [bool]$enabledBox.IsChecked
                Program = [string]$firstAction.Program
                Arguments = [string]$firstAction.Arguments
                WorkingDirectory = [string]$firstAction.WorkingDirectory
                BackgroundMode = [bool]$backgroundBox.IsChecked
                LogDirectory = [string]$logDirectoryBox.Text
                Environment = $envVars
                TriggerKind = $firstTrigger.Kind
                StartDateTime = $firstTrigger.StartDate.Date.Add([TimeSpan]::Parse($firstTrigger.StartTime))
                RepeatMinutes = $firstTrigger.RepeatMinutes
                Overwrite = $overwrite
                Actions = [object[]]$actionList
                Triggers = [object[]]$triggerList
            }
            $window.DialogResult = $true
        }
        catch {
            [void][Windows.MessageBox]::Show(
                $window, $_.Exception.Message,
                '输入无效',
                [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Warning
            )
        }
    })

    try {
        if ($window.ShowDialog()) {
            return $window.Tag
        }
        return $null
    }
    finally {
        $script:__envVarRows = $null
        $script:__envVarsPanel = $null
        $script:__actionRows = $null
        $script:__actionsPanel = $null
        $script:__triggerRows = $null
        $script:__triggersPanel = $null
    }
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
    try {
        $window = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
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
        Title="TaskHub - 轻量级任务计划管理器"
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
          <Separator/>
          <ToggleButton x:Name="BackgroundFilterButton" Padding="12,5" Content="仅显示后台应用"/>
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
try {
    $script:MainWindow = [Windows.Markup.XamlReader]::Load($mainReader)
}
finally {
    $mainReader.Dispose()
}
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

$script:RefreshButton.Add_Click({ Update-All })
$script:TaskGrid.Add_SelectionChanged({ Update-TaskDetails })
$script:TaskGrid.Add_MouseDoubleClick({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) { return }
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
        Set-Status -Text ('编辑失败：{0}' -f $message)
    }
    finally {
        Set-Busy -Busy $false
        Update-All
    }
})
$script:FolderTree.Add_SelectedItemChanged({
    if (-not $script:IsBusy -and $null -ne $script:FolderTree.SelectedItem) {
        Update-TaskList -FolderPath ([string]$script:FolderTree.SelectedItem.Tag)
    }
})

$script:MainWindow.FindName('RunButton').Add_Click({
    Invoke-WithSelectedTask -OperationName '立即运行' -Operation {
        param($folder, $task, $model)
        $running = $task.Run($null)
        Clear-ComObject $running
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
                Clear-ComObject $taskAction
                Clear-ComObject $actions
                Clear-ComObject $definition
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
                Clear-ComObject $taskAction
                Clear-ComObject $actions
                Clear-ComObject $definition
            }
            # Stop running background instances before deletion so that
            # the wrapper and its child processes are terminated before
            # file cleanup. Regular tasks follow system Task Scheduler
            # behavior (delete does not stop running instances).
            if ($null -ne $runtimeInfo -and [int]$task.State -eq 4) {
                try {
                    $task.Stop(0)
                    Write-AppLog -Message ('删除前已停止运行中的后台应用：{0}' -f $model.Path)
                }
                catch {
                    Write-AppLog -Level WARN -Message ('删除前停止后台应用失败：{0}；{1}' -f $model.Path, $_.Exception.Message)
                }
            }
            $parts = Split-RegisteredTaskPath $model.Path
            $folder.DeleteTask($parts.Name, 0)
            Remove-EmptyTaskFolder -FolderPath $parts.Folder
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

$script:MainWindow.FindName('BackgroundFilterButton').Add_Click({
    $script:ShowBackgroundOnly = [bool]$this.IsChecked
    if ($script:ShowBackgroundOnly) {
        Set-Status -Text '已过滤：仅显示后台应用'
    }
    else {
        Set-Status -Text '已取消过滤'
    }
    Update-All
})

$script:MainWindow.FindName('ExportXmlButton').Add_Click({
    $selected = $script:TaskGrid.SelectedItem
    if ($null -eq $selected) {
        Show-InfoMessage '请先选择一个任务。'
        return
    }
    $dialog = $null
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
    finally {
        if ($null -ne $dialog) { $dialog.Dispose() }
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
        Update-All
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
        Update-All
    }
})

$script:MainWindow.Add_ContentRendered({
    Update-All
})
$script:MainWindow.Add_Closed({
    Write-AppLog -Message '应用已关闭。'
    Clear-ComObject $script:TaskService
    $script:TaskService = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
})

Write-AppLog -Message ('应用启动；PowerShell={0}；ApartmentState={1}' -f $PSVersionTable.PSVersion, [Threading.Thread]::CurrentThread.ApartmentState)
if ($SmokeTest) {
    try {
        Connect-TaskService
        $smokeErrors = @(Update-FolderTree)
        $smokeModels = @(Get-FolderTaskModels -FolderPath '\')
        Write-Output ('SMOKE OK: STA={0}; Folders={1}; RootTasks={2}; SkippedFolders={3}; Icon={4}' -f
            [Threading.Thread]::CurrentThread.ApartmentState,
            $script:FolderPaths.Count,
            $smokeModels.Count,
            $smokeErrors.Count,
            $script:MainIconLoaded)
    }
    finally {
        Clear-ComObject $script:TaskService
        $script:TaskService = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    return
}
[void]$script:MainWindow.ShowDialog()
