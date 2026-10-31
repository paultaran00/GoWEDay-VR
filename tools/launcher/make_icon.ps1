# Draws the launcher icon (original art: a red cog with a VR headset) -> icon.ico (256/48/32/16, PNG entries) + icon_256.png.
# Run once; make_build.bat embeds icon.ico in GoWEDay_VR.exe.
Add-Type -AssemblyName System.Drawing
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Draw-Icon {
    $n = 256
    $bmp = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $c = $n / 2

    # cog: 10 teeth around a ring
    $teeth = 10; $rOut = 124; $rIn = 100
    $pts = New-Object System.Collections.Generic.List[System.Drawing.PointF]
    for ($i = 0; $i -lt $teeth; $i++) {
        $a0 = 2 * [math]::PI * $i / $teeth
        $step = 2 * [math]::PI / $teeth
        foreach ($f in @(@(0.00, $rIn), @(0.12, $rOut), @(0.38, $rOut), @(0.50, $rIn))) {
            $a = $a0 + $f[0] * $step
            $pts.Add((New-Object System.Drawing.PointF ([single]($c + $f[1] * [math]::Cos($a))), ([single]($c + $f[1] * [math]::Sin($a)))))
        }
    }
    $red = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, 0), (New-Object System.Drawing.Point 0, $n),
        ([System.Drawing.Color]::FromArgb(255, 222, 40, 30)), ([System.Drawing.Color]::FromArgb(255, 120, 10, 8))
    $g.FillPolygon($red, $pts.ToArray())
    # dark face inside the cog
    $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 24, 24, 26))
    $g.FillEllipse($dark, $c - 86, $c - 86, 172, 172)

    # VR headset: visor with rounded corners, strap stubs, two lenses, nose notch
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = $c - 70; $y = $c - 34; $w = 140; $h = 68; $r = 26
    $path.AddArc($x, $y, $r, $r, 180, 90); $path.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
    $path.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90)
    $path.AddLine([single]($c + 16), [single]($y + $h), [single]($c + 8), [single]($y + $h - 16))
    $path.AddLine([single]($c - 8), [single]($y + $h - 16), [single]($c - 16), [single]($y + $h))
    $path.AddArc($x, $y + $h - $r, $r, $r, 90, 90); $path.CloseFigure()
    $grey = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, $y), (New-Object System.Drawing.Point 0, ($y + $h)),
        ([System.Drawing.Color]::FromArgb(255, 235, 235, 238)), ([System.Drawing.Color]::FromArgb(255, 150, 152, 160))
    $g.FillRectangle($grey, $c - 84, $c - 10, 16, 20); $g.FillRectangle($grey, $c + 68, $c - 10, 16, 20)
    $g.FillPath($grey, $path)
    $lens = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 200, 30, 22))
    $g.FillEllipse($lens, $c - 52, $c - 18, 34, 30); $g.FillEllipse($lens, $c + 18, $c - 18, 34, 30)
    $g.Dispose()
    return $bmp
}

$big = Draw-Icon
$big.Save((Join-Path $here 'icon_256.png'), [System.Drawing.Imaging.ImageFormat]::Png)

# .ico with PNG-compressed entries (Vista+)
$sizes = 256, 48, 32, 16
$pngs = foreach ($s in $sizes) {
    $b = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($b); $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'
    $g.DrawImage($big, 0, 0, $s, $s); $g.Dispose()
    $ms = New-Object System.IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray()
}
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
[System.IO.File]::WriteAllBytes((Join-Path $here 'icon.ico'), $out.ToArray())
"icon.ico: $($out.Length) bytes"
