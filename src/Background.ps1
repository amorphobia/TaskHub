function New-BackgroundActionValues {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory
    )
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wrapperPath = Join-Path $RuntimeDirectory 'wrapper.ps1'
    return [PSCustomObject]@{
        RuntimeDirectory = $RuntimeDirectory
        WrapperPath = $wrapperPath
        ConfigPath = Join-Path $RuntimeDirectory 'config.json'
        DefaultLogDirectory = Join-Path $RuntimeDirectory 'logs'
        PowershellPath = $powershellPath
        ActionPath = $powershellPath
        ActionArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "{0}"' -f $wrapperPath
    }
}

function Set-MainWindowIcon {
    param([Parameter(Mandatory = $true)][Windows.Window]$Window)

    # The repository source contains a short marker. build.ps1 replaces it with
    # an in-memory ICO; direct source execution remains valid but has no custom icon.
    if ([string]::IsNullOrWhiteSpace($script:EmbeddedIconBase64) -or
        $script:EmbeddedIconBase64.Length -lt 100) {
        return $false
    }

    $stream = $null
    try {
        $iconBytes = [Convert]::FromBase64String($script:EmbeddedIconBase64)
        $stream = New-Object IO.MemoryStream(, $iconBytes)
        $decoder = New-Object Windows.Media.Imaging.IconBitmapDecoder(
            $stream,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        )
        $frame = $decoder.Frames |
            Sort-Object PixelWidth, PixelHeight -Descending |
            Select-Object -First 1
        if ($null -eq $frame) {
            throw '嵌入的 ICO 不包含可用图像。'
        }
        $Window.Icon = $frame
        return $true
    }
    catch {
        Write-AppLog -Level WARN -Message ('加载嵌入图标失败：{0}' -f $_.Exception.Message)
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Update-TaskContextMenu {
    param([AllowNull()][object]$TaskModel = $script:TaskGrid.SelectedItem)

    $hasTask = $null -ne $TaskModel
    $isEnabled = $hasTask -and [bool]$TaskModel.Enabled
    $visible = [Windows.Visibility]::Visible
    $collapsed = [Windows.Visibility]::Collapsed

    $script:TaskContextRunItem.Visibility = if ($isEnabled) { $visible } else { $collapsed }
    $script:TaskContextStopItem.Visibility = if ($isEnabled) { $visible } else { $collapsed }
    $script:TaskContextDisableItem.Visibility = if ($isEnabled) { $visible } else { $collapsed }
    $script:TaskContextEnableItem.Visibility = if ($hasTask -and -not $isEnabled) { $visible } else { $collapsed }
    $script:TaskContextExportItem.Visibility = if ($hasTask) { $visible } else { $collapsed }
    $script:TaskContextDeleteItem.Visibility = if ($hasTask) { $visible } else { $collapsed }
}

function Invoke-MainToolbarAction {
    param([Parameter(Mandatory = $true)][string]$ButtonName)

    if ($script:IsBusy) { return }
    $button = $script:MainWindow.FindName($ButtonName)
    if ($null -eq $button -or -not $button.IsEnabled) { return }
    $clickEvent = New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)
    $button.RaiseEvent($clickEvent)
}

function Get-BackgroundActionValues {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    return New-BackgroundActionValues -RuntimeDirectory (Get-BackgroundRuntimeDirectory $FullTaskPath)
}

function Get-BackgroundActionCandidates {
    param([Parameter(Mandatory = $true)][string]$FullTaskPath)
    return @(Get-BackgroundActionValues $FullTaskPath)
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
        foreach ($values in @(Get-BackgroundActionCandidates $FullTaskPath)) {
            if ($null -ne $Action -and
                (-not [string]::Equals([string]$Action.Path, $values.ActionPath, [StringComparison]::OrdinalIgnoreCase) -or
                 -not [string]::Equals([string]$Action.Arguments, $values.ActionArguments, [StringComparison]::OrdinalIgnoreCase))) {
                continue
            }
            $config = Read-BackgroundConfig $values.ConfigPath
            if ($null -eq $config -or $null -eq $config.PSObject.Properties['Version'] -or
                [int]$config.Version -ne 1 -or
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
                RuntimeDirectory = $values.RuntimeDirectory
                WrapperPath = $values.WrapperPath
                ConfigPath = $values.ConfigPath
                DefaultLogDirectory = $values.DefaultLogDirectory
                LogDirectory = $resolvedLog.Path
                LogDirectoryIsDefault = $resolvedLog.IsDefault
                StdOutPath = Join-Path $resolvedLog.Path 'stdout.log'
                StdErrPath = Join-Path $resolvedLog.Path 'stderr.log'
                WrapperErrorPath = Join-Path $resolvedLog.Path 'wrapper-error.log'
                PowershellPath = $values.PowershellPath
                ActionPath = $values.ActionPath
                ActionArguments = $values.ActionArguments
                Config = $config
                Environment = if ($null -ne $config.PSObject.Properties['Environment']) { $config.Environment } else { $null }
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
            if ([string]::Equals([string]$Action.Path, $values.ActionPath, [StringComparison]::OrdinalIgnoreCase) -and
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

    $managedPaths = @($values.WrapperPath, $values.ConfigPath)
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
        $envObject = @{}
        if ($null -ne $Data.PSObject.Properties['Environment'] -and $null -ne $Data.Environment) {
            foreach ($key in $Data.Environment.Keys) {
                $envObject[$key] = [string]$Data.Environment[$key]
            }
        }
        $config = [ordered]@{
            Version = 1
            TaskFullPath = $FullTaskPath
            TaskName = [string]$Data.TaskName
            Executable = [string]$Data.Program
            Arguments = [string]$Data.Arguments
            WorkingDirectory = [string]$Data.WorkingDirectory
            LogDirectory = $resolvedLog.Path
            LogDirectoryIsDefault = $resolvedLog.IsDefault
            Environment = $envObject
        }
        $configJson = $config | ConvertTo-Json -Depth 3
        [IO.File]::WriteAllText($values.WrapperPath, $script:BackgroundWrapperContent, (New-Object Text.UTF8Encoding($true)))
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
    $expectedDirectory = [IO.Path]::GetFullPath((Get-BackgroundRuntimeDirectory $RuntimeInfo.FullTaskPath))
    if (-not [string]::Equals($runtimeDirectory, $expectedDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw '拒绝清理：后台运行目录与完整任务路径不匹配。'
    }

    foreach ($path in @($RuntimeInfo.WrapperPath, $RuntimeInfo.ConfigPath)) {
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

