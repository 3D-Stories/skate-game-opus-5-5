# Drives the running Windows build for the native input and sound test (desktop/input_test_windows.sh):
#
#   drive.ps1 -exe C:\Temp\ProSkater\ProSkater.exe -steps "wait:6;tap:RETURN;hold:W:1500;..." -out <file>
#
# Keyboard: every step posts WM_KEYDOWN / WM_KEYUP to the game's window (PostMessage), the same
# window messages a key press turns into, so the window never needs (or takes) the focus.
#   wait:<ms>  tap:<key>  hold:<key>:<ms>  down:<key>  up:<key>   (<key>: a System.Windows.Forms.Keys name)
#   shot:<png file>   picture of the game's window alone, frame and title bar included
#                     (PrintWindow: nothing else on the screen is captured)
# Sound: while the steps run, the game process's audio session on the default output device is
# found through the Windows Core Audio API and its peak meter (what the volume mixer shows) is
# read every 50 ms: proof that Windows' audio engine gets sound from the game.
# Writes one JSON object to -out: the steps as posted, and the audio session's samples.
param([string]$exe, [string]$steps, [string]$out)
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumerator {}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice device);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
  int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr g, int f, out IntPtr c);
  int GetSimpleAudioVolume(IntPtr g, int f, out IntPtr v);
  int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionEnumerator {
  int GetCount(out int n);
  int GetSession(int i, out IAudioSessionControl2 s);
}
[Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionControl2 {
  int GetState(out int s);
  int GetDisplayName(out IntPtr n);
  int SetDisplayName(IntPtr n, IntPtr g);
  int GetIconPath(out IntPtr p);
  int SetIconPath(IntPtr p, IntPtr g);
  int GetGroupingParam(out Guid g);
  int SetGroupingParam(IntPtr g, IntPtr c);
  int RegisterAudioSessionNotification(IntPtr n);
  int UnregisterAudioSessionNotification(IntPtr n);
  int GetSessionIdentifier(out IntPtr s);
  int GetSessionInstanceIdentifier(out IntPtr s);
  int GetProcessId(out uint pid);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioMeterInformation { int GetPeakValue(out float peak); }
public static class Meter {
  // peak of the process's session on the default render device; -1 when it has no session (yet)
  public static float Peak(uint pid, out int state) {
    state = -1;
    var en = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
    IMMDevice dev; en.GetDefaultAudioEndpoint(0, 1, out dev);
    Guid iid = typeof(IAudioSessionManager2).GUID; object o; dev.Activate(ref iid, 23, IntPtr.Zero, out o);
    IAudioSessionEnumerator se; ((IAudioSessionManager2)o).GetSessionEnumerator(out se);
    int n; se.GetCount(out n);
    for (int i = 0; i < n; i++) {
      IAudioSessionControl2 s; se.GetSession(i, out s);
      uint p; s.GetProcessId(out p);
      if (p == pid) { float v; ((IAudioMeterInformation)s).GetPeakValue(out v); s.GetState(out state); return v; }
    }
    return -1f;
  }
}
"@
$name = [IO.Path]::GetFileNameWithoutExtension($exe)
$proc = $null
for ($i = 0; $i -lt 200 -and -not $proc; $i++) {
  $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $proc) { Start-Sleep -Milliseconds 100 }
}
if (-not $proc) { '{"error": "no game window"}' | Out-File -Encoding utf8 $out; exit 1 }
$hwnd = $proc.MainWindowHandle
$posted = New-Object System.Collections.ArrayList
$audio = New-Object System.Collections.ArrayList
$sw = [Diagnostics.Stopwatch]::StartNew()
function Sample { $st = 0; $pk = [Meter]::Peak([uint32]$proc.Id, [ref]$st); [void]$audio.Add(@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 2); peak = [math]::Round($pk, 4); state = $st }) }
function Pause-Ms([int]$ms) { $end = $sw.ElapsedMilliseconds + $ms; while ($sw.ElapsedMilliseconds -lt $end) { Sample; Start-Sleep -Milliseconds 50 } }
function Key([string]$k, [bool]$down) {
  $vk = [uint32][System.Windows.Forms.Keys]$k
  $sc = [Win]::MapVirtualKey($vk, 0)
  $l = 1 -bor ($sc -shl 16)
  if (-not $down) { $l = $l -bor 0xC0000000 }
  [void][Win]::PostMessage($hwnd, $(if ($down) { 0x100 } else { 0x101 }), [IntPtr]$vk, [IntPtr][int64]([uint32]$l))
  [void]$posted.Add(@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 2); key = $k; down = $down })
}
function Shot([string]$file) {
  $r = New-Object Win+RECT; [void][Win]::GetWindowRect($hwnd, [ref]$r)
  $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
  $ok = [Win]::PrintWindow($hwnd, $dc, 2)          # PW_RENDERFULLCONTENT: GPU-drawn content too
  $g.ReleaseHdc($dc); $g.Dispose(); $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  [void]$posted.Add(@{ t = [math]::Round($sw.Elapsed.TotalSeconds, 2); shot = $file; ok = $ok; size = "$($r.R - $r.L)x$($r.B - $r.T)" })
}
foreach ($st in $steps.Split(";")) {
  if ($proc.HasExited) { break }
  $p = $st.Split(":")
  switch ($p[0]) {
    "wait" { Pause-Ms ([int]$p[1]) }
    "tap" { Key $p[1] $true; Pause-Ms 120; Key $p[1] $false; Pause-Ms 150 }
    "hold" { Key $p[1] $true; Pause-Ms ([int]$p[2]); Key $p[1] $false; Pause-Ms 150 }
    "down" { Key $p[1] $true }
    "up" { Key $p[1] $false }
    "shot" { Shot ($st.Substring(5)) }
  }
}
for ($i = 0; $i -lt 100 -and -not $proc.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
@{ pid = $proc.Id; hwnd = [int64]$hwnd; exited = $proc.HasExited; keys = $posted; audio = $audio } | ConvertTo-Json -Depth 4 -Compress | Out-File -Encoding utf8 $out
