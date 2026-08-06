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

