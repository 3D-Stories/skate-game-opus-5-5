# Prints the monitor that contains the rectangle x,y,w,h (Windows virtual-desktop pixels) and the
# desktop's top-left corner, which Godot 4 measures window positions from:
#   "<device> primary=<True|False> <bounds> origin=<x>,<y>"   ("none ..." when no one monitor holds it)
# desktop/run_windows.sh uses it to refuse to open a test window on the primary monitor.
param([int]$x, [int]$y, [int]$w, [int]$h)
Add-Type -AssemblyName System.Windows.Forms
$all = [System.Windows.Forms.Screen]::AllScreens
$ox = ($all | ForEach-Object { $_.Bounds.X } | Measure-Object -Minimum).Minimum
$oy = ($all | ForEach-Object { $_.Bounds.Y } | Measure-Object -Minimum).Minimum
$r = New-Object System.Drawing.Rectangle $x, $y, $w, $h
$hit = $all | Where-Object { $_.Bounds.Contains($r) } | Select-Object -First 1
if ($hit) { "$($hit.DeviceName) primary=$($hit.Primary) $($hit.Bounds) origin=$ox,$oy" } else { "none origin=$ox,$oy" }
