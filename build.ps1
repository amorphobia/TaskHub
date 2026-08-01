#requires -version 5.1
<#
    Builds UserTaskManager.ps1 into a self-starting CMD/PowerShell polyglot.
    The generated file runs with the caller's token in Windows PowerShell STA.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDirectory = [IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $scriptDirectory 'UserTaskManager.ps1'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $scriptDirectory 'UserTaskManager.cmd'
}

function Get-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

$sourceFullPath = Get-FullPath $SourcePath
$outputFullPath = Get-FullPath $OutputPath

if (-not [IO.File]::Exists($sourceFullPath)) {
    throw ('找不到源脚本：{0}' -f $sourceFullPath)
}
if ([IO.Path]::GetExtension($outputFullPath) -ine '.cmd') {
    throw ('输出文件必须使用 .cmd 扩展名：{0}' -f $outputFullPath)
}
if ([string]::Equals($sourceFullPath, $outputFullPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw '源脚本和输出文件不能是同一个文件。'
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $sourceFullPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object {
        '第 {0} 行，第 {1} 列：{2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
    }
    throw ("源脚本语法检查失败：`n{0}" -f ($details -join [Environment]::NewLine))
}

$sourceText = [IO.File]::ReadAllText($sourceFullPath, [Text.Encoding]::UTF8)
$header = @'
<# :
  @echo off
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" /nologo /noprofile -STA -WindowStyle Hidden /command ^
    "&{try{& ([ScriptBlock]::Create((Get-Content """%~f0""" -Encoding UTF8) -join [Char[]]10)) %*}catch{Write-Error $_;exit 1}}"
  exit /b %errorlevel%
#>

'@
$header = $header -replace "`r?`n", "`r`n"

# The output intentionally has no BOM so cmd.exe sees a plain ASCII first line.
# The wrapper explicitly decodes the complete polyglot as UTF-8 in PowerShell 5.1,
# preserving all Unicode source text and paths without using the active ANSI code page.
$utf8WithoutBom = New-Object Text.UTF8Encoding($false)
$outputDirectory = [IO.Path]::GetDirectoryName($outputFullPath)
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and
    -not [IO.Directory]::Exists($outputDirectory)) {
    [void][IO.Directory]::CreateDirectory($outputDirectory)
}
[IO.File]::WriteAllText($outputFullPath, $header + $sourceText, $utf8WithoutBom)

$outputInfo = Get-Item -LiteralPath $outputFullPath
Write-Host ('构建成功：{0}' -f $outputInfo.FullName) -ForegroundColor Green
Write-Host ('文件大小：{0} 字节' -f $outputInfo.Length)
Write-Host '启动方式：双击生成的 CMD，或从命令行运行它。'
