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
$script:MainIconLoaded = $false
$script:TaskContextMenu = $null
$script:TaskContextRunItem = $null
$script:TaskContextStopItem = $null
$script:TaskContextDisableItem = $null
$script:TaskContextEnableItem = $null
$script:TaskContextExportItem = $null
$script:TaskContextDeleteItem = $null
$script:FolderPaths = New-Object 'System.Collections.Generic.List[string]'
$script:CurrentFolderPath = '\'
$script:CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:CurrentSid = $script:CurrentIdentity.User.Value
$script:CurrentUserName = $script:CurrentIdentity.Name
$script:LogDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'UserTaskManager'
$script:LogPath = Join-Path $script:LogDirectory 'UserTaskManager.log'
$script:EmbeddedIconBase64 = '__USER_TASK_MANAGER_ICON_BASE64__'

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
