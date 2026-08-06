#requires -version 5.1
<#
    Builds UserTaskManager.ps1 into a self-starting CMD/PowerShell polyglot.
    The generated file runs with the caller's token in Windows PowerShell STA.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$IconPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptDirectory = [IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $scriptDirectory 'UserTaskManager.cmd'
}
if ([string]::IsNullOrWhiteSpace($IconPath)) {
    $IconPath = Join-Path $scriptDirectory 'assets\UserTaskManager.svg'
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

$outputFullPath = Get-FullPath $OutputPath
$iconFullPath = Get-FullPath $IconPath

if (-not [IO.File]::Exists($iconFullPath)) {
    throw ('找不到 SVG 图标母版：{0}' -f $iconFullPath)
}
if ([IO.Path]::GetExtension($outputFullPath) -ine '.cmd') {
    throw ('输出文件必须使用 .cmd 扩展名：{0}' -f $outputFullPath)
}
Add-Type -AssemblyName PresentationCore, WindowsBase

function Get-SvgAttribute {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )
    if ($Element.HasAttribute($Name)) {
        return $Element.GetAttribute($Name)
    }
    return $DefaultValue
}

function ConvertFrom-SvgNumber {
    param(
        [AllowNull()][object]$Value,
        [double]$DefaultValue = 0
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $DefaultValue
    }
    return [double]::Parse(
        [string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function New-SvgBrush {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][string]$AttributeName
    )
    $value = [string](Get-SvgAttribute -Element $Element -Name $AttributeName -DefaultValue 'none')
    if ([string]::IsNullOrWhiteSpace($value) -or $value -ieq 'none') {
        return $null
    }
    $color = [Windows.Media.ColorConverter]::ConvertFromString($value)
    $brush = New-Object Windows.Media.SolidColorBrush($color)
    $opacityText = Get-SvgAttribute -Element $Element -Name ($AttributeName + '-opacity')
    if ($null -eq $opacityText) {
        $opacityText = Get-SvgAttribute -Element $Element -Name 'opacity'
    }
    if ($null -ne $opacityText) {
        $brush.Opacity = ConvertFrom-SvgNumber -Value $opacityText -DefaultValue 1
    }
    $brush.Freeze()
    return $brush
}

function New-SvgPen {
    param([Parameter(Mandatory = $true)][Xml.XmlElement]$Element)
    $brush = New-SvgBrush -Element $Element -AttributeName 'stroke'
    if ($null -eq $brush) { return $null }
    $width = ConvertFrom-SvgNumber -Value (Get-SvgAttribute -Element $Element -Name 'stroke-width') -DefaultValue 1
    $pen = New-Object Windows.Media.Pen($brush, $width)
    if ([string](Get-SvgAttribute -Element $Element -Name 'stroke-linecap') -ieq 'round') {
        $pen.StartLineCap = [Windows.Media.PenLineCap]::Round
        $pen.EndLineCap = [Windows.Media.PenLineCap]::Round
    }
    if ([string](Get-SvgAttribute -Element $Element -Name 'stroke-linejoin') -ieq 'round') {
        $pen.LineJoin = [Windows.Media.PenLineJoin]::Round
    }
    $pen.Freeze()
    return $pen
}

function Draw-SvgElement {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlElement]$Element,
        [Parameter(Mandatory = $true)][Windows.Media.DrawingContext]$DrawingContext
    )
    $fill = New-SvgBrush -Element $Element -AttributeName 'fill'
    $pen = New-SvgPen -Element $Element
    switch ($Element.LocalName) {
        'rect' {
            $x = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'x')
            $y = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'y')
            $width = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'width')
            $height = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'height')
            $radiusX = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'rx')
            $radiusYValue = Get-SvgAttribute $Element 'ry'
            $radiusY = if ($null -eq $radiusYValue) { $radiusX } else { ConvertFrom-SvgNumber $radiusYValue }
            $DrawingContext.DrawRoundedRectangle($fill, $pen, (New-Object Windows.Rect($x, $y, $width, $height)), $radiusX, $radiusY)
        }
        'circle' {
            $center = New-Object Windows.Point(
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'cx')),
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'cy'))
            )
            $radius = ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'r')
            $DrawingContext.DrawEllipse($fill, $pen, $center, $radius, $radius)
        }
        'line' {
            $start = New-Object Windows.Point(
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'x1')),
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'y1'))
            )
            $end = New-Object Windows.Point(
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'x2')),
                (ConvertFrom-SvgNumber (Get-SvgAttribute $Element 'y2'))
            )
            if ($null -ne $pen) {
                $DrawingContext.DrawLine($pen, $start, $end)
            }
        }
        'path' {
            $data = [string](Get-SvgAttribute $Element 'd')
            if ([string]::IsNullOrWhiteSpace($data)) {
                throw 'SVG path 缺少 d 属性。'
            }
            $geometry = [Windows.Media.Geometry]::Parse($data)
            $DrawingContext.DrawGeometry($fill, $pen, $geometry)
        }
        default {
            throw ('SVG 图标包含构建器不支持的元素：{0}' -f $Element.LocalName)
        }
    }
}

function Convert-SvgToPngBytes {
    param(
        [Parameter(Mandatory = $true)][Xml.XmlDocument]$SvgDocument,
        [Parameter(Mandatory = $true)][int]$Size
    )
    $root = $SvgDocument.DocumentElement
    if ($null -eq $root -or $root.LocalName -ne 'svg') {
        throw '图标母版根元素必须是 svg。'
    }
    $viewBoxParts = @(([string]$root.GetAttribute('viewBox')) -split '[,\s]+' | Where-Object { $_ })
    if ($viewBoxParts.Count -ne 4) {
        throw 'SVG 图标必须提供四个数值组成的 viewBox。'
    }
    $viewX = ConvertFrom-SvgNumber $viewBoxParts[0]
    $viewY = ConvertFrom-SvgNumber $viewBoxParts[1]
    $viewWidth = ConvertFrom-SvgNumber $viewBoxParts[2]
    $viewHeight = ConvertFrom-SvgNumber $viewBoxParts[3]
    if ($viewWidth -le 0 -or $viewHeight -le 0) {
        throw 'SVG viewBox 尺寸无效。'
    }

    $visual = New-Object Windows.Media.DrawingVisual
    $drawingContext = $visual.RenderOpen()
    try {
        $drawingContext.PushTransform((New-Object Windows.Media.ScaleTransform(
            ($Size / $viewWidth),
            ($Size / $viewHeight)
        )))
        $drawingContext.PushTransform((New-Object Windows.Media.TranslateTransform(-$viewX, -$viewY)))
        foreach ($child in $root.ChildNodes) {
            if ($child -is [Xml.XmlElement]) {
                Draw-SvgElement -Element $child -DrawingContext $drawingContext
            }
        }
        $drawingContext.Pop()
        $drawingContext.Pop()
    }
    finally {
        $drawingContext.Close()
    }

    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(
        $Size,
        $Size,
        96,
        96,
        [Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($visual)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = New-Object IO.MemoryStream
    try {
        $encoder.Save($stream)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Convert-SvgToIconBase64 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $svgDocument = New-Object Xml.XmlDocument
    $svgDocument.PreserveWhitespace = $true
    $svgDocument.LoadXml([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($size in @(16, 20, 24, 32, 48, 64, 128, 256)) {
        $entries.Add([PSCustomObject]@{
            Size = $size
            Png = [byte[]](Convert-SvgToPngBytes -SvgDocument $svgDocument -Size $size)
        })
    }

    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($stream, [Text.Encoding]::UTF8, $true)
    try {
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]$entries.Count)
        $offset = 6 + (16 * $entries.Count)
        foreach ($entry in $entries) {
            $dimension = if ($entry.Size -eq 256) { [byte]0 } else { [byte]$entry.Size }
            $writer.Write($dimension)
            $writer.Write($dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]32)
            $writer.Write([UInt32]$entry.Png.Length)
            $writer.Write([UInt32]$offset)
            $offset += $entry.Png.Length
        }
        foreach ($entry in $entries) {
            $writer.Write([byte[]]$entry.Png)
        }
        $writer.Flush()
        return [Convert]::ToBase64String($stream.ToArray())
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

$sourceFiles = @(
    'UserTaskManager.ps1',
    'WrapperContent.ps1',
    'Utilities.ps1',
    'Background.ps1',
    'TaskManager.ps1',
    'Dialogs.ps1'
)
$srcDirectory = Join-Path $scriptDirectory 'src'
$sourceTextBuilder = New-Object Text.StringBuilder
foreach ($file in $sourceFiles) {
    $fullPath = Join-Path $srcDirectory $file
    if (-not [IO.File]::Exists($fullPath)) {
        throw ('找不到源文件：{0}' -f $fullPath)
    }
    [void]$sourceTextBuilder.Append([IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8))
}
$sourceText = $sourceTextBuilder.ToString()

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput(
    $sourceText,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object {
        '第 {0} 行，第 {1} 列：{2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
    }
    throw ("源脚本语法检查失败：`n{0}" -f ($details -join [Environment]::NewLine))
}
$iconMarker = '__USER_TASK_MANAGER_ICON_BASE64__'
$markerCount = [Text.RegularExpressions.Regex]::Matches(
    $sourceText,
    [Text.RegularExpressions.Regex]::Escape($iconMarker)
).Count
if ($markerCount -ne 1) {
    throw ('主脚本必须且只能包含一个图标注入标记；实际数量：{0}' -f $markerCount)
}
$iconBase64 = Convert-SvgToIconBase64 -Path $iconFullPath
$sourceText = $sourceText.Replace($iconMarker, $iconBase64)
$header = @'
<# :
  @echo off
  set "_WS=-WindowStyle Hidden"
  if not "%*"=="" set "_WS="
  "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" /nologo /noprofile -STA %_WS% /command ^
    "&{try{& ([ScriptBlock]::Create((Get-Content """%~f0""" -Encoding UTF8) -join [Char[]]10)) @args}catch{Write-Error $_;exit 1}}" %*
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
Write-Host ('图标：{0}（内存渲染 8 个 PNG 尺寸并打包 ICO）' -f $iconFullPath)
Write-Host '启动方式：双击生成的 CMD，或从命令行运行它。'
