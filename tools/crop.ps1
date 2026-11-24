Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile("c:\Users\xing\Documents\1\chaoshu\tools\shot_commit.png")
$rects = @(
  @{x=0; y=150; w=1300; h=90; name="hint"},
  @{x=0; y=230; w=1300; h=260; name="left"}
)
foreach ($r in $rects) {
  $bmp = New-Object System.Drawing.Bitmap $r.w, $r.h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,$r.w,$r.h), (New-Object System.Drawing.Rectangle $r.x,$r.y,$r.w,$r.h), [System.Drawing.GraphicsUnit]::Pixel)
  $g.Dispose()
  $bmp.Save("c:\Users\xing\Documents\1\chaoshu\tools\crop_$($r.name).png", [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}
$src.Dispose()
Write-Output "cropped"
