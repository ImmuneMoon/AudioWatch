<#
.SYNOPSIS
  Watches Windows audio output devices and logs what changes them.

.DESCRIPTION
  Uses the Windows Core Audio API to log, with millisecond timestamps:
    - default output/input device changes (per role: Console, Multimedia, Communications)
    - devices being added, removed, enabled, disabled, unplugged
    - apps opening/closing audio sessions, and which device each app is playing on
    - master volume / mute changes on the default output
  When the default output changes it also records the foreground app, the
  processes that started in the previous 15 seconds, and what is playing where.

  If the default output device goes away (disabled, unplugged, not present),
  it raises a drop-out alert: a red console line, a running count in the
  window title, and a Windows notification (at most one per -AlertEverySeconds).

  Everything is printed to the console and appended to a log file.
  Press Ctrl+C to stop.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\AudioWatch.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\AudioWatch.ps1 -ShowPropertyChanges
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\AudioWatch.ps1 -TestAlert
#>
param(
    [int]$PollMs = 1000,             # how often to poll sessions / volume / processes
    [switch]$ShowPropertyChanges,    # also log low-level device property changes (noisy)
    [string]$LogPath,                # default: audio-watch-<timestamp>.log next to this script
    [int]$Seconds = 0,               # stop after N seconds (0 = run until Ctrl+C)
    [int]$AlertEverySeconds = 60,    # at most one desktop notification per this many seconds
    [switch]$NoAlerts,               # turn off desktop notifications
    [switch]$TestAlert               # show one test notification and exit
)

$ErrorActionPreference = 'Stop'
if (-not $LogPath) {
    $LogPath = Join-Path $PSScriptRoot ("audio-watch-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

$cs = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace AudioWatch
{
    public enum EDataFlow { Render = 0, Capture = 1, All = 2 }
    public enum ERole { Console = 0, Multimedia = 1, Communications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropVariant { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

    [ComImport, Guid("7991EEC9-7E89-4D85-8390-6C703CEC60C0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMNotificationClient
    {
        [PreserveSig] int OnDeviceStateChanged([MarshalAs(UnmanagedType.LPWStr)] string id, int state);
        [PreserveSig] int OnDeviceAdded([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDeviceRemoved([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnDefaultDeviceChanged(EDataFlow flow, ERole role, [MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int OnPropertyValueChanged([MarshalAs(UnmanagedType.LPWStr)] string id, PropertyKey key);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow flow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow flow, ERole role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IMMNotificationClient client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IMMNotificationClient client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetAt(int index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr guid, int flags, out IntPtr ctl);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr guid, int flags, out IntPtr vol);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionControl2
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName(IntPtr a, IntPtr b);
        [PreserveSig] int GetIconPath(IntPtr a);
        [PreserveSig] int SetIconPath(IntPtr a, IntPtr b);
        [PreserveSig] int GetGroupingParam(IntPtr a);
        [PreserveSig] int SetGroupingParam(IntPtr a, IntPtr b);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr a);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr a);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr n);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr n);
        [PreserveSig] int GetChannelCount(out uint c);
        [PreserveSig] int SetMasterVolumeLevel(float l, IntPtr ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float l, IntPtr ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float l);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float l);
        [PreserveSig] int SetChannelVolumeLevel(uint ch, float l, IntPtr ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(uint ch, float l, IntPtr ctx);
        [PreserveSig] int GetChannelVolumeLevel(uint ch, out float l);
        [PreserveSig] int GetChannelVolumeLevelScalar(uint ch, out float l);
        [PreserveSig] int SetMute(bool m, IntPtr ctx);
        [PreserveSig] int GetMute(out bool m);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorCo { }

    public class AudioEvent
    {
        public DateTime Time; public string Kind; public string DeviceId; public string Detail;
        public EDataFlow Flow; public ERole Role;
    }

    public class NotificationClient : IMMNotificationClient
    {
        public ConcurrentQueue<AudioEvent> Queue = new ConcurrentQueue<AudioEvent>();
        void Add(string kind, string id, string detail, EDataFlow flow, ERole role)
        {
            AudioEvent e = new AudioEvent();
            e.Time = DateTime.Now; e.Kind = kind; e.DeviceId = id; e.Detail = detail; e.Flow = flow; e.Role = role;
            Queue.Enqueue(e);
        }
        public int OnDeviceStateChanged(string id, int state) { Add("StateChanged", id, Audio.StateName(state), EDataFlow.All, ERole.Console); return 0; }
        public int OnDeviceAdded(string id) { Add("Added", id, null, EDataFlow.All, ERole.Console); return 0; }
        public int OnDeviceRemoved(string id) { Add("Removed", id, null, EDataFlow.All, ERole.Console); return 0; }
        public int OnDefaultDeviceChanged(EDataFlow flow, ERole role, string id) { Add("DefaultChanged", id, null, flow, role); return 0; }
        public int OnPropertyValueChanged(string id, PropertyKey key) { Add("PropertyChanged", id, key.fmtid + "," + key.pid, EDataFlow.All, ERole.Console); return 0; }
    }

    public class DeviceInfo { public string Id; public string Name; public int State; public string StateName; }
    public class SessionInfo { public string DeviceId; public uint Pid; public string Process; public string DisplayName; public int State; public string StateName; public string Key; }

    public static class Audio
    {
        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant pv);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);

        const int CLSCTX_ALL = 23;
        static IMMDeviceEnumerator en;
        static Dictionary<string, string> names = new Dictionary<string, string>();

        public static IMMDeviceEnumerator Enumerator
        {
            get { if (en == null) en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCo()); return en; }
        }

        public static int Register(NotificationClient c) { return Enumerator.RegisterEndpointNotificationCallback(c); }
        public static int Unregister(NotificationClient c) { return Enumerator.UnregisterEndpointNotificationCallback(c); }

        public static string StateName(int s)
        {
            switch (s) { case 1: return "Active"; case 2: return "Disabled"; case 4: return "NotPresent"; case 8: return "Unplugged"; default: return "State" + s; }
        }

        public static string Name(string id)
        {
            if (string.IsNullOrEmpty(id)) return "(none)";
            string n;
            lock (names) { if (names.TryGetValue(id, out n)) return n; }
            string result = id;
            try
            {
                IMMDevice d;
                if (Enumerator.GetDevice(id, out d) == 0 && d != null)
                {
                    IPropertyStore ps;
                    if (d.OpenPropertyStore(0, out ps) == 0 && ps != null)
                    {
                        PropertyKey k = new PropertyKey();
                        k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14; // PKEY_Device_FriendlyName
                        PropVariant pv;
                        if (ps.GetValue(ref k, out pv) == 0)
                        {
                            if (pv.vt == 31 && pv.p != IntPtr.Zero) result = Marshal.PtrToStringUni(pv.p);
                            PropVariantClear(ref pv);
                        }
                        Marshal.ReleaseComObject(ps);
                    }
                    Marshal.ReleaseComObject(d);
                }
            }
            catch { }
            lock (names) { names[id] = result; }
            return result;
        }

        public static string DefaultId(EDataFlow flow, ERole role)
        {
            IMMDevice d;
            if (Enumerator.GetDefaultAudioEndpoint(flow, role, out d) != 0 || d == null) return null;
            string id; d.GetId(out id);
            Marshal.ReleaseComObject(d);
            return id;
        }

        public static List<DeviceInfo> Devices(EDataFlow flow, int stateMask)
        {
            List<DeviceInfo> list = new List<DeviceInfo>();
            IMMDeviceCollection c;
            if (Enumerator.EnumAudioEndpoints(flow, stateMask, out c) != 0 || c == null) return list;
            int n; c.GetCount(out n);
            for (int i = 0; i < n; i++)
            {
                IMMDevice d;
                if (c.Item(i, out d) != 0 || d == null) continue;
                string id; d.GetId(out id);
                int st; d.GetState(out st);
                DeviceInfo info = new DeviceInfo();
                info.Id = id; info.Name = Name(id); info.State = st; info.StateName = StateName(st);
                list.Add(info);
                Marshal.ReleaseComObject(d);
            }
            Marshal.ReleaseComObject(c);
            return list;
        }

        public static string ProcName(uint pid)
        {
            if (pid == 0) return "System";
            try { using (System.Diagnostics.Process p = System.Diagnostics.Process.GetProcessById((int)pid)) return p.ProcessName; }
            catch { return "pid" + pid; }
        }

        public static List<SessionInfo> Sessions(string deviceId)
        {
            List<SessionInfo> list = new List<SessionInfo>();
            IMMDevice d;
            if (Enumerator.GetDevice(deviceId, out d) != 0 || d == null) return list;
            try
            {
                Guid iid = typeof(IAudioSessionManager2).GUID;
                object o;
                if (d.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) != 0 || o == null) return list;
                IAudioSessionManager2 mgr = (IAudioSessionManager2)o;
                IAudioSessionEnumerator e;
                if (mgr.GetSessionEnumerator(out e) == 0 && e != null)
                {
                    int n; e.GetCount(out n);
                    for (int i = 0; i < n; i++)
                    {
                        object so;
                        if (e.GetSession(i, out so) != 0 || so == null) continue;
                        IAudioSessionControl2 s = so as IAudioSessionControl2;
                        if (s != null)
                        {
                            SessionInfo info = new SessionInfo();
                            info.DeviceId = deviceId;
                            int st; s.GetState(out st);
                            info.State = st;
                            info.StateName = st == 1 ? "Active" : (st == 0 ? "Inactive" : "Expired");
                            uint pid; s.GetProcessId(out pid);
                            info.Pid = pid;
                            string dn; s.GetDisplayName(out dn); info.DisplayName = dn;
                            string inst; s.GetSessionInstanceIdentifier(out inst);
                            info.Key = string.IsNullOrEmpty(inst) ? (deviceId + "|" + pid) : inst;
                            info.Process = s.IsSystemSoundsSession() == 0 ? "SystemSounds" : ProcName(pid);
                            list.Add(info);
                        }
                        Marshal.ReleaseComObject(so);
                    }
                    Marshal.ReleaseComObject(e);
                }
                Marshal.ReleaseComObject(mgr);
            }
            catch { }
            finally { Marshal.ReleaseComObject(d); }
            return list;
        }

        public static string Volume(string deviceId)
        {
            if (string.IsNullOrEmpty(deviceId)) return null;
            IMMDevice d;
            if (Enumerator.GetDevice(deviceId, out d) != 0 || d == null) return null;
            try
            {
                Guid iid = typeof(IAudioEndpointVolume).GUID;
                object o;
                if (d.Activate(ref iid, CLSCTX_ALL, IntPtr.Zero, out o) != 0 || o == null) return null;
                IAudioEndpointVolume v = (IAudioEndpointVolume)o;
                float l; bool m;
                v.GetMasterVolumeLevelScalar(out l); v.GetMute(out m);
                Marshal.ReleaseComObject(v);
                return ((int)Math.Round(l * 100)) + "%" + (m ? " (MUTED)" : "");
            }
            catch { return null; }
            finally { Marshal.ReleaseComObject(d); }
        }

        public static string Foreground()
        {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return "(none)";
            uint pid; GetWindowThreadProcessId(h, out pid);
            StringBuilder sb = new StringBuilder(256);
            GetWindowText(h, sb, 256);
            return ProcName(pid) + " (pid " + pid + ") \"" + sb.ToString() + "\"";
        }
    }
}
'@

if (-not ('AudioWatch.Audio' -as [type])) { Add-Type -TypeDefinition $cs -Language CSharp }

$Render  = [AudioWatch.EDataFlow]::Render
$Capture = [AudioWatch.EDataFlow]::Capture
$Roles   = [AudioWatch.ERole]::Console, [AudioWatch.ERole]::Multimedia, [AudioWatch.ERole]::Communications

function Log([string]$msg, [string]$color = 'Gray', [datetime]$time = (Get-Date)) {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f $time, $msg
    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}
function DevName([string]$id) { [AudioWatch.Audio]::Name($id) }

# ---- alerts: desktop notification + window title + highlighted console line ----
$ToastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$toastOk = $false
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $toastOk = $true
} catch { }

function Notify([string]$title, [string]$text) {
    if ($NoAlerts) { return }
    if ($script:toastOk) {
        try {
            $t = [Security.SecurityElement]::Escape($title); $b = [Security.SecurityElement]::Escape($text)
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show(
                [Windows.UI.Notifications.ToastNotification]::new($xml))
            return
        } catch { }
    }
    try { [console]::Beep(880, 250) } catch { }
}

$watchStart   = Get-Date
$dropCount    = 0
$dropsSinceAlert = 0
$lastAlert    = [datetime]::MinValue
$lastDropTime = $null

function SetTitle {
    $last = if ($script:lastDropTime) { ', last {0:HH:mm:ss}' -f $script:lastDropTime } else { '' }
    try { $Host.UI.RawUI.WindowTitle = "Audio watch - $($script:dropCount) drop-outs since {0:HH:mm}$last" -f $script:watchStart } catch { }
}

function OnDropOut([string]$name, [string]$state, [datetime]$t) {
    $script:dropCount++
    $script:dropsSinceAlert++
    $script:lastDropTime = $t
    $line = '{0:HH:mm:ss.fff}  !!! DROP-OUT #{1}: default output [{2}] went {3} !!!' -f $t, $script:dropCount, $name, $state
    Write-Host $line -ForegroundColor White -BackgroundColor DarkRed
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    SetTitle
    if (((Get-Date) - $script:lastAlert).TotalSeconds -ge $AlertEverySeconds) {
        $extra = if ($script:dropsSinceAlert -gt 1) { " ($($script:dropsSinceAlert) since last alert)" } else { '' }
        Notify "Audio drop-out #$($script:dropCount)" ("{0} went {1} at {2:HH:mm:ss}{3}. Music may need to be restarted." -f $name, $state, $t, $extra)
        $script:lastAlert = Get-Date
        $script:dropsSinceAlert = 0
    }
}

if ($TestAlert) {
    Notify 'Audio watch test' 'If you can see this, drop-out alerts will work.'
    Write-Host "Test notification sent (toast available: $toastOk)."
    return
}
function DevKind([string]$id) { if ($id -like '{0.0.1.*') { 'input' } else { 'output' } }

# ---- process tracking (to see what launched right before a change) ----
$known = @{}
Get-Process | ForEach-Object { $known[$_.Id] = $_.ProcessName }
$procStarts = @()
function PollProcesses {
    $now = Get-Date
    $seen = @{}
    foreach ($p in Get-Process) {
        $seen[$p.Id] = $p.ProcessName
        if (-not $script:known.ContainsKey($p.Id)) {
            $script:procStarts += [pscustomobject]@{ Time = $now; Id = $p.Id; Name = $p.ProcessName }
        }
    }
    $script:known = $seen
    $cut = $now.AddMinutes(-2)
    $script:procStarts = @($script:procStarts | Where-Object { $_.Time -ge $cut })
}

# ---- session tracking (which app plays on which device) ----
$sessState = @{}
function PollSessions([bool]$quiet = $false) {
    $now = @{}
    foreach ($d in [AudioWatch.Audio]::Devices($Render, 1)) {
        foreach ($s in [AudioWatch.Audio]::Sessions($d.Id)) {
            $now[$s.Key] = $s
            if ($quiet) { continue }
            $old = $script:sessState[$s.Key]
            if ($null -eq $old) {
                Log ("SESSION  {0} (pid {1}) opened audio on [{2}] - {3}" -f $s.Process, $s.Pid, $d.Name, $s.StateName) 'Cyan'
            } elseif ($old.State -ne $s.State) {
                Log ("SESSION  {0} (pid {1}) on [{2}]: {3} -> {4}" -f $s.Process, $s.Pid, $d.Name, $old.StateName, $s.StateName) 'DarkCyan'
            }
        }
    }
    if (-not $quiet) {
        foreach ($k in @($script:sessState.Keys)) {
            if (-not $now.ContainsKey($k)) {
                $o = $script:sessState[$k]
                Log ("SESSION  {0} (pid {1}) closed on [{2}]" -f $o.Process, $o.Pid, (DevName $o.DeviceId)) 'DarkCyan'
            }
        }
    }
    $script:sessState = $now
}

function Snapshot {
    Log ("   foreground app   : " + [AudioWatch.Audio]::Foreground()) 'Yellow'
    $cut = (Get-Date).AddSeconds(-15)
    $recent = @($script:procStarts | Where-Object { $_.Time -ge $cut })
    if ($recent.Count) {
        Log ("   started <15s ago : " + (($recent | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', ')) 'Yellow'
    } else {
        Log  "   started <15s ago : (none seen)" 'DarkYellow'
    }
    foreach ($d in [AudioWatch.Audio]::Devices($Render, 1)) {
        $act = @([AudioWatch.Audio]::Sessions($d.Id) | Where-Object { $_.State -eq 1 })
        $who = if ($act.Count) { ($act | ForEach-Object { "$($_.Process) ($($_.Pid))" }) -join ', ' } else { '-' }
        Log ("   playing on [{0}] : {1}" -f $d.Name, $who) 'Yellow'
    }
}

# ---- state shared by events and polling ----
$lastDefault = @{}
foreach ($r in $Roles) { $lastDefault[[int]$r] = [AudioWatch.Audio]::DefaultId($Render, $r) }
$lastVolume = [AudioWatch.Audio]::Volume($lastDefault[0])
$lastSnapshot = [datetime]::MinValue

function OnDefaultOutputChanged([string]$role, [string]$id, [datetime]$t, [string]$how) {
    Log ("DEFAULT OUTPUT ({0}) -> [{1}]{2}" -f $role, (DevName $id), $how) 'Red' $t
    if (((Get-Date) - $script:lastSnapshot).TotalSeconds -gt 2) {
        Snapshot
        $script:lastSnapshot = Get-Date
    }
}

function HandleEvent($e) {
    $name = DevName $e.DeviceId
    switch ($e.Kind) {
        'DefaultChanged' {
            if ($e.Flow -eq $Render) {
                $script:lastDefault[[int]$e.Role] = $e.DeviceId
                OnDefaultOutputChanged $e.Role $e.DeviceId $e.Time ''
            } else {
                Log ("default input ({0}) -> [{1}]" -f $e.Role, $name) 'Magenta' $e.Time
            }
        }
        'StateChanged'    {
            Log ("DEVICE   {0} [{1}] is now {2}" -f (DevKind $e.DeviceId), $name, $e.Detail) 'Yellow' $e.Time
            if ($e.Detail -ne 'Active' -and $e.DeviceId -eq $script:lastDefault[0]) { OnDropOut $name $e.Detail $e.Time }
        }
        'Added'           { Log ("DEVICE   {0} [{1}] added"      -f (DevKind $e.DeviceId), $name) 'Yellow' $e.Time }
        'Removed'         { Log ("DEVICE   {0} [{1}] removed"    -f (DevKind $e.DeviceId), $name) 'Yellow' $e.Time }
        'PropertyChanged' { if ($ShowPropertyChanges) { Log ("prop     [{0}] {1}" -f $name, $e.Detail) 'DarkGray' $e.Time } }
    }
}

# ---- startup summary ----
Log "Audio watch started. Logging to $LogPath" 'Green'
Log "Output devices (active / disabled / unplugged):" 'Green'
foreach ($d in [AudioWatch.Audio]::Devices($Render, 11)) { Log ("   [{0}] {1}" -f $d.Name, $d.StateName) 'Gray' }
foreach ($r in $Roles) { Log ("Default output ({0}): [{1}]" -f $r, (DevName $lastDefault[[int]$r])) 'Green' }
Log ("Default output volume: {0}" -f $lastVolume) 'Green'
PollSessions $true
foreach ($s in $sessState.Values) { Log ("   session: {0} (pid {1}) on [{2}] - {3}" -f $s.Process, $s.Pid, (DevName $s.DeviceId), $s.StateName) 'Gray' }
Log "Watching... (Ctrl+C to stop)" 'Green'
SetTitle
Notify 'Audio watch is running' ("Watching {0}. You'll get an alert when it drops out." -f (DevName $lastDefault[0]))

$client = New-Object AudioWatch.NotificationClient
[void][AudioWatch.Audio]::Register($client)
$start = Get-Date
$lastPoll = [datetime]::MinValue

try {
    while ($true) {
        $ev = $null
        while ($client.Queue.TryDequeue([ref]$ev)) { HandleEvent $ev }

        if (((Get-Date) - $lastPoll).TotalMilliseconds -ge $PollMs) {
            $lastPoll = Get-Date
            PollProcesses
            PollSessions

            # Fallback check in case a notification was missed
            foreach ($r in $Roles) {
                $cur = [AudioWatch.Audio]::DefaultId($Render, $r)
                if ($cur -ne $lastDefault[[int]$r]) {
                    $lastDefault[[int]$r] = $cur
                    OnDefaultOutputChanged $r $cur (Get-Date) '  (detected by poll)'
                }
            }

            $vol = [AudioWatch.Audio]::Volume($lastDefault[0])
            if ($vol -ne $lastVolume) {
                Log ("VOLUME   [{0}] {1} -> {2}  (foreground: {3})" -f (DevName $lastDefault[0]), $lastVolume, $vol, [AudioWatch.Audio]::Foreground()) 'White'
                $lastVolume = $vol
            }
        }

        if ($Seconds -gt 0 -and ((Get-Date) - $start).TotalSeconds -ge $Seconds) { break }
        Start-Sleep -Milliseconds 200
    }
}
finally {
    [void][AudioWatch.Audio]::Unregister($client)
    Log "Stopped." 'Green'
}
