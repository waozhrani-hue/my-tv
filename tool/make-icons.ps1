# Generates the My TV app icon for Android and Windows.
# The mark: a rounded teal tile with a dark TV set and a play triangle,
# matching the in-app AppLogo so the launcher icon and the app agree.

param([string]$ProjectRoot = 'C:\Projects\My tv')

Add-Type -AssemblyName System.Drawing

$TEAL_LIGHT = [System.Drawing.Color]::FromArgb(255, 60, 240, 196)
$TEAL_DARK  = [System.Drawing.Color]::FromArgb(255, 14, 150, 126)
$INK        = [System.Drawing.Color]::FromArgb(255, 6, 32, 28)

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# Draws the TV mark centred on an S-sized canvas, scaled by $scale.
function Draw-Mark([System.Drawing.Graphics]$g, [single]$S, [single]$scale, [System.Drawing.Color]$ink) {
  $cx = $S / 2.0
  $cy = $S / 2.0
  $u = $S * $scale          # the mark occupies $scale of the canvas
  $stroke = $u * 0.075
  $pen = New-Object System.Drawing.Pen($ink, $stroke)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

  # Screen body, sitting slightly below centre to leave room for the antennae.
  $bw = $u * 0.82
  $bh = $u * 0.60
  $bx = $cx - $bw / 2.0
  $by = $cy - $bh / 2.0 + $u * 0.09
  $body = New-RoundedPath $bx $by $bw $bh ($u * 0.11)
  $g.DrawPath($pen, $body)
  $body.Dispose()

  # Antennae.
  $ay = $by - $u * 0.21
  $g.DrawLine($pen, ($cx - $u * 0.10), $by, ($cx - $u * 0.26), $ay)
  $g.DrawLine($pen, ($cx + $u * 0.10), $by, ($cx + $u * 0.26), $ay)

  # Play triangle inside the screen.
  $tc = $by + $bh / 2.0
  $th = $u * 0.26
  $tw = $u * 0.23
  $brush = New-Object System.Drawing.SolidBrush($ink)
  $pts = @(
    (New-Object System.Drawing.PointF(($cx - $tw * 0.42), ($tc - $th / 2.0))),
    (New-Object System.Drawing.PointF(($cx - $tw * 0.42), ($tc + $th / 2.0))),
    (New-Object System.Drawing.PointF(($cx + $tw * 0.70), $tc))
  )
  $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
  $tri.AddPolygon([System.Drawing.PointF[]]$pts)
  $g.FillPath($brush, $tri)
  $tri.Dispose(); $brush.Dispose(); $pen.Dispose()
}

function New-Canvas([int]$S) {
  $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  return @($bmp, $g)
}

# Full icon: gradient tile + mark.
function New-Icon([int]$S) {
  $c = New-Canvas $S; $bmp = $c[0]; $g = $c[1]
  $g.Clear([System.Drawing.Color]::Transparent)
  $tile = New-RoundedPath 0 0 $S $S ($S * 0.225)
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    (New-Object System.Drawing.PointF(0, 0)),
    (New-Object System.Drawing.PointF($S, $S)), $TEAL_LIGHT, $TEAL_DARK)
  $g.FillPath($brush, $tile)
  $brush.Dispose(); $tile.Dispose()
  Draw-Mark $g $S 0.58 $INK
  $g.Dispose()
  return $bmp
}

# Adaptive foreground: the mark alone, inside the 66/108 safe zone.
function New-Foreground([int]$S) {
  $c = New-Canvas $S; $bmp = $c[0]; $g = $c[1]
  $g.Clear([System.Drawing.Color]::Transparent)
  Draw-Mark $g $S 0.40 $INK
  $g.Dispose()
  return $bmp
}

function Save-Png($bmp, [string]$path) {
  $dir = Split-Path $path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}

# --- Android ---------------------------------------------------------------

$res = Join-Path $ProjectRoot 'android\app\src\main\res'
$legacy = @{ 'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96; 'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192 }
foreach ($k in $legacy.Keys) {
  $b = New-Icon $legacy[$k]
  Save-Png $b (Join-Path $res "$k\ic_launcher.png")
  $b.Dispose()
}
$fg = @{ 'drawable-mdpi' = 108; 'drawable-hdpi' = 162; 'drawable-xhdpi' = 216; 'drawable-xxhdpi' = 324; 'drawable-xxxhdpi' = 432 }
foreach ($k in $fg.Keys) {
  $b = New-Foreground $fg[$k]
  Save-Png $b (Join-Path $res "$k\ic_launcher_foreground.png")
  $b.Dispose()
}

# Android TV banner: 320x180, mark on the left with the wordmark beside it.
$banner = New-Object System.Drawing.Bitmap(320, 180, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$bg = [System.Drawing.Graphics]::FromImage($banner)
$bg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$bg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$bg.Clear([System.Drawing.Color]::FromArgb(255, 10, 13, 18))
$mark = New-Icon 92
$bg.DrawImage($mark, 34, 44, 92, 92)
$mark.Dispose()
$font = New-Object System.Drawing.Font('Segoe UI', 30, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$bg.DrawString('My TV', $font, $white, 142, 74)
$font.Dispose(); $white.Dispose(); $bg.Dispose()
Save-Png $banner (Join-Path $res 'drawable\tv_banner.png')
$banner.Dispose()

# --- Windows .ico ----------------------------------------------------------
# Built by hand: ICONDIR + one ICONDIRENTRY per size, each holding a PNG.
# Windows Vista and later read PNG-compressed entries directly.

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngs = @()
foreach ($s in $sizes) {
  $b = New-Icon $s
  $ms = New-Object System.IO.MemoryStream
  $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += , $ms.ToArray()
  $ms.Dispose(); $b.Dispose()
}

$icoPath = Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico'
$fs = [System.IO.File]::Create($icoPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]
  $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
  $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))
  $bw.Write([byte]0)            # palette
  $bw.Write([byte]0)            # reserved
  $bw.Write([uint16]1)          # colour planes
  $bw.Write([uint16]32)         # bits per pixel
  $bw.Write([uint32]$pngs[$i].Length)
  $bw.Write([uint32]$offset)
  $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush(); $bw.Close(); $fs.Close()

"Android icons  : $res"
"Windows icon   : $icoPath ($((Get-Item $icoPath).Length) bytes, $($sizes.Count) sizes)"
