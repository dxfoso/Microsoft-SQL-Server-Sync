Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

function New-RoundedRectanglePath([float]$x, [float]$y, [float]$width, [float]$height, [float]$radius) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $diameter = $radius * 2
  $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
  $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
  $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  return $path
}

function Save-ScaledPng([System.Drawing.Bitmap]$source, [int]$size, [string]$path) {
  $bitmap = New-Object System.Drawing.Bitmap $size, $size
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $graphics.DrawImage($source, 0, 0, $size, $size)
  $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $graphics.Dispose()
  $bitmap.Dispose()
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$masterPath = Join-Path $PSScriptRoot 'sync-icon-master.png'
$frontendWeb = Join-Path $repoRoot 'frontend\web'
$adminWeb = Join-Path $repoRoot 'sync_admin_web\web'
$windowsIcon = Join-Path $repoRoot 'sync_windows_agent\windows\runner\resources\app_icon.ico'

$size = 1024
$bitmap = New-Object System.Drawing.Bitmap $size, $size
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$graphics.Clear([System.Drawing.Color]::Transparent)

$bgColor = [System.Drawing.ColorTranslator]::FromHtml('#1F5D67')
$panelColor = [System.Drawing.ColorTranslator]::FromHtml('#F3F6F5')
$panelBorder = [System.Drawing.ColorTranslator]::FromHtml('#D8E6E3')
$arrowColor = [System.Drawing.ColorTranslator]::FromHtml('#1F5D67')

$bgBrush = New-Object System.Drawing.SolidBrush $bgColor
$panelBrush = New-Object System.Drawing.SolidBrush $panelColor
$arrowBrush = New-Object System.Drawing.SolidBrush $arrowColor
$panelPen = New-Object System.Drawing.Pen $panelBorder, 14

$bgPath = New-RoundedRectanglePath 36 36 952 952 210
$graphics.FillPath($bgBrush, $bgPath)

$panelPath = New-RoundedRectanglePath 232 232 560 560 112
$graphics.FillPath($panelBrush, $panelPath)
$graphics.DrawPath($panelPen, $panelPath)

$topShaft = New-RoundedRectanglePath 330 366 246 84 42
$graphics.FillPath($arrowBrush, $topShaft)
$topHead = [System.Drawing.Point[]]@(
  [System.Drawing.Point]::new(558, 330),
  [System.Drawing.Point]::new(706, 408),
  [System.Drawing.Point]::new(558, 486)
)
$graphics.FillPolygon($arrowBrush, $topHead)

$bottomShaft = New-RoundedRectanglePath 446 574 246 84 42
$graphics.FillPath($arrowBrush, $bottomShaft)
$bottomHead = [System.Drawing.Point[]]@(
  [System.Drawing.Point]::new(464, 538),
  [System.Drawing.Point]::new(316, 616),
  [System.Drawing.Point]::new(464, 694)
)
$graphics.FillPolygon($arrowBrush, $bottomHead)

$bitmap.Save($masterPath, [System.Drawing.Imaging.ImageFormat]::Png)

Save-ScaledPng $bitmap 48 (Join-Path $frontendWeb 'favicon.png')
Save-ScaledPng $bitmap 192 (Join-Path $frontendWeb 'icons\Icon-192.png')
Save-ScaledPng $bitmap 512 (Join-Path $frontendWeb 'icons\Icon-512.png')
Save-ScaledPng $bitmap 192 (Join-Path $frontendWeb 'icons\Icon-maskable-192.png')
Save-ScaledPng $bitmap 512 (Join-Path $frontendWeb 'icons\Icon-maskable-512.png')

Save-ScaledPng $bitmap 48 (Join-Path $adminWeb 'favicon.png')
Save-ScaledPng $bitmap 192 (Join-Path $adminWeb 'icons\Icon-192.png')
Save-ScaledPng $bitmap 512 (Join-Path $adminWeb 'icons\Icon-512.png')
Save-ScaledPng $bitmap 192 (Join-Path $adminWeb 'icons\Icon-maskable-192.png')
Save-ScaledPng $bitmap 512 (Join-Path $adminWeb 'icons\Icon-maskable-512.png')

$iconPngPath = Join-Path $PSScriptRoot 'sync-icon-256.png'
Save-ScaledPng $bitmap 256 $iconPngPath

$graphics.Dispose()
$bitmap.Dispose()
$bgBrush.Dispose()
$panelBrush.Dispose()
$arrowBrush.Dispose()
$panelPen.Dispose()
$bgPath.Dispose()
$panelPath.Dispose()
$topShaft.Dispose()
$bottomShaft.Dispose()

$ffmpeg = Get-Command ffmpeg -ErrorAction Stop
& $ffmpeg.Source -y -loglevel error -i $iconPngPath $windowsIcon
Remove-Item $iconPngPath

Write-Output "Updated icon assets from $masterPath"
