# Finds where a test window goes: centred on the monitor named -name (DISPLAY2 by default),
# and prints "<x> <y> <device> primary=<True|False> <bounds> origin=<ox>,<oy>", where x,y is
# the top-left of a -w x -h client area (with a -top px title bar above it) in Windows desktop
# pixels, and origin is the desktop's top-left corner (Godot 4 places windows from there).
# Prints "none" when that monitor is missing or too small. desktop/run_windows.sh refuses to
# open a window on the primary monitor: the PC's user works there. Monitors can be rearranged
# at any time, so this is asked again before every run.
param([string]$name = "DISPLAY2", [int]$w = 1920, [int]$h = 1080, [int]$top = 40)
Add-Type -AssemblyName System.Windows.Forms
$all = [System.Windows.Forms.Screen]::AllScreens
$ox = ($all | ForEach-Object { $_.Bounds.X } | Measure-Object -Minimum).Minimum
$oy = ($all | ForEach-Object { $_.Bounds.Y } | Measure-Object -Minimum).Minimum
$s = $all | Where-Object { $_.DeviceName -eq "\\.\$name" } | Select-Object -First 1
if (-not $s -or $s.WorkingArea.Width -lt $w -or $s.WorkingArea.Height -lt ($h + $top)) { "none origin=$ox,$oy"; exit }
$x = $s.WorkingArea.X + [int](($s.WorkingArea.Width - $w) / 2)
$y = $s.WorkingArea.Y + $top + [int](($s.WorkingArea.Height - $h - $top) / 2)
"$x $y $($s.DeviceName) primary=$($s.Primary) $($s.Bounds) origin=$ox,$oy"
