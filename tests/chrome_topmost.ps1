Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
}
"@
$ids = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object { $_.CommandLine -like '*skatebench*' } | ForEach-Object { [uint32]$_.ProcessId }
$found = @()
$cb = [W+EnumProc]{ param($h, $l)
  $procId = [uint32]0; [void][W]::GetWindowThreadProcessId($h, [ref]$procId)
  if ($ids -contains $procId -and [W]::IsWindowVisible($h)) {
    $sb = New-Object System.Text.StringBuilder 256; [void][W]::GetWindowText($h, $sb, 256)
    if ($sb.Length -gt 0) { $script:found += "$h $($sb.ToString())"; [void][W]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0013) }
  }
  return $true }
[void][W]::EnumWindows($cb, [IntPtr]::Zero)
"topmost: " + ($found -join '; ')
