# Lists every monitor: device, primary, bounds, work area, mode and refresh rate.
# desktop/bench_windows.sh records it before and after each run (monitors can be rearranged).
Add-Type @"
using System; using System.Runtime.InteropServices;
public class D {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE { [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName; public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput; public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName; public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency; public int a,b,c,d,e,f,g,h; }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
}
"@
Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) { $dm = New-Object D+DEVMODE; $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm); [void][D]::EnumDisplaySettings($s.DeviceName, -1, [ref]$dm); "$($s.DeviceName) primary=$($s.Primary) bounds=$($s.Bounds) work=$($s.WorkingArea) $($dm.dmPelsWidth)x$($dm.dmPelsHeight)@$($dm.dmDisplayFrequency)Hz" }
