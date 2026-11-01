// Gears of War: E-Day VR - launcher.
// Built by tools\launcher\make_build.bat with the csc.exe of .NET Framework 4 (no extra downloads).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

static class Launcher
{
    const string ExeName = "GoWEDay-Steam.exe";
    const string ExeRel = @"FairlightConcept\Binaries\Win64\" + ExeName;
    static readonly string Here = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string SettingsFile = Path.Combine(Here, "path.txt");

    [STAThread]
    static int Main(string[] args)
    {
        SetProcessDPIAware(); // real monitor pixels for the Fullscreen size
        if (args.Length == 1 && args[0] == "--selftest") return SelfTest();
        Application.EnableVisualStyles();
        Application.Run(new LauncherForm());
        return 0;
    }

    // ---- path.txt: "GameFolder=...", "Windowed=True|False", "GlobalPlugins=True|False" lines ----
    public static Dictionary<string, string> LoadSettings()
    {
        var d = new Dictionary<string, string>();
        if (!File.Exists(SettingsFile)) return d;
        foreach (var line in File.ReadAllLines(SettingsFile))
        {
            int i = line.IndexOf('=');
            if (i > 0) d[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
        }
        return d;
    }

    public static void SaveSettings(string folder, bool windowed, bool globalPlugins)
    {
        File.WriteAllLines(SettingsFile, new[] { "GameFolder=" + folder, "Windowed=" + windowed, "GlobalPlugins=" + globalPlugins });
    }

    // Any install (Steam, Xbox app, any folder name): a folder is searched for the game exe; an exe is used as is,
    // unless it is a launcher stub (EAC start_protected_game.exe, Xbox gamelaunchhelper.exe) -> its folder is searched.
    static readonly string[] NotTheGame = { "start_protected_game", "gamelaunchhelper", "EasyAntiCheat", "EpicWebHelper",
        "CrashReport", "crashpad_handler", "GamingRepair", "UnrealCEFSubProcess", "UEVR", "GoWEDay_VR" };

    static bool IsStub(string exe)
    {
        string n = Path.GetFileName(exe);
        return NotTheGame.Any(x => n.IndexOf(x, StringComparison.OrdinalIgnoreCase) >= 0);
    }

    public static string FindGameExe(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try { path = Path.GetFullPath(path.Trim().Trim('"')); } catch { return null; }
        if (File.Exists(path))
        {
            if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) path = Path.GetDirectoryName(path);
            else if (!IsStub(path)) return path;
            else path = Path.GetDirectoryName(path);
        }
        if (!Directory.Exists(path)) return null;
        // UE game exe = <Project>\Binaries\<Win64|WinGDK>\*.exe; Engine\Binaries holds only tools
        return AllExes(path)
            .Where(f => !IsStub(f))
            .Select(f => new { f, rel = @"\" + f.Substring(path.Length).TrimStart('\\') })
            .Where(x => x.rel.IndexOf(@"\Engine\", StringComparison.OrdinalIgnoreCase) < 0 &&
                        (x.rel.IndexOf(@"\Binaries\", StringComparison.OrdinalIgnoreCase) >= 0 || !x.rel.TrimStart('\\').Contains('\\')))
            .OrderByDescending(x => Path.GetFileName(x.f).StartsWith("GoWEDay", StringComparison.OrdinalIgnoreCase))
            .ThenBy(x => x.rel.Length)
            .Select(x => x.f).FirstOrDefault();
    }

    // recursive *.exe listing that skips folders we may not read (WindowsApps etc.)
    static IEnumerable<string> AllExes(string dir)
    {
        var stack = new Stack<string>(); stack.Push(dir);
        while (stack.Count > 0)
        {
            string d = stack.Pop();
            string[] files = new string[0], subs = new string[0];
            try { files = Directory.GetFiles(d, "*.exe"); subs = Directory.GetDirectories(d); } catch { }
            foreach (var f in files) yield return f;
            foreach (var s in subs) stack.Push(s);
        }
    }

    // Steam copy: needs steam_appid.txt / SteamAppId to start directly. The Xbox app copy must not get them.
    public static bool IsSteamCopy(string gameExe)
    {
        return gameExe.IndexOf(@"\steamapps\", StringComparison.OrdinalIgnoreCase) >= 0 ||
               Path.GetFileName(gameExe).IndexOf("Steam", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    // the game keeps its own resolution; only window or full screen is chosen here
    public static string WindowArgs(bool windowed)
    {
        return windowed ? "-windowed" : "-fullscreen";
    }

    // ---- UEVR injector settings: force OpenXR ----
    // The injector (.NET single file) keeps its radio buttons in
    // %LOCALAPPDATA%\praydog\UEVRInjector_Path_<hash>\1.0.0.0\user.config, default OpenVR.
    // hash = ClientConfigPaths: SHA1 of BinaryWriter.Write(lowercase exe path .ToUpperInvariant()), dir-name base32.
    public static string InjectorConfigDir(string injectorExe)
    {
        string path = Path.GetFullPath(injectorExe).ToLowerInvariant().ToUpperInvariant();
        var ms = new MemoryStream();
        new BinaryWriter(ms, Encoding.UTF8).Write(path);
        byte[] h = SHA1.Create().ComputeHash(ms.ToArray());
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "praydog", "UEVRInjector_Path_" + Base32(h), "1.0.0.0");
    }

    static string Base32(byte[] buff)
    {
        const string a = "abcdefghijklmnopqrstuvwxyz012345";
        var sb = new StringBuilder();
        int i = 0, l = buff.Length;
        do
        {
            byte b0 = i < l ? buff[i++] : (byte)0, b1 = i < l ? buff[i++] : (byte)0, b2 = i < l ? buff[i++] : (byte)0,
                 b3 = i < l ? buff[i++] : (byte)0, b4 = i < l ? buff[i++] : (byte)0;
            sb.Append(a[b0 & 0x1F]).Append(a[b1 & 0x1F]).Append(a[b2 & 0x1F]).Append(a[b3 & 0x1F]).Append(a[b4 & 0x1F]);
            sb.Append(a[((b0 & 0xE0) >> 5) | ((b3 & 0x60) >> 2)]);
            sb.Append(a[((b1 & 0xE0) >> 5) | ((b4 & 0x60) >> 2)]);
            int c = (b2 & 0xE0) >> 5;
            if ((b3 & 0x80) != 0) c |= 0x08;
            if ((b4 & 0x80) != 0) c |= 0x10;
            sb.Append(a[c]);
        } while (i < l);
        return sb.ToString();
    }

    const string InjectorConfigTemplate =
@"<?xml version=""1.0"" encoding=""utf-8""?>
<configuration>
  <configSections>
    <sectionGroup name=""userSettings"" type=""System.Configuration.UserSettingsGroup, System.Configuration.ConfigurationManager, Version=6.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51"">
      <section name=""UEVR.MainWindowSettings"" type=""System.Configuration.ClientSettingsSection, System.Configuration.ConfigurationManager, Version=6.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51"" allowExeDefinition=""MachineToLocalUser"" requirePermission=""false"" />
    </sectionGroup>
  </configSections>
  <userSettings>
    <UEVR.MainWindowSettings>
      <setting name=""OpenXRRadio"" serializeAs=""String"">
        <value>True</value>
      </setting>
      <setting name=""FocusGameOnInjection"" serializeAs=""String"">
        <value>True</value>
      </setting>
      <setting name=""OpenVRRadio"" serializeAs=""String"">
        <value>False</value>
      </setting>
      <setting name=""IgnoreFutureVDWarnings"" serializeAs=""String"">
        <value>False</value>
      </setting>
      <setting name=""NullifyVRPluginsCheckbox"" serializeAs=""String"">
        <value>True</value>
      </setting>
    </UEVR.MainWindowSettings>
  </userSettings>
</configuration>
";

    public static void ForceOpenXR(string injectorExe)
    {
        string dir = InjectorConfigDir(injectorExe), file = Path.Combine(dir, "user.config");
        if (!File.Exists(file))
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(file, InjectorConfigTemplate);
            return;
        }
        var doc = new System.Xml.XmlDocument();
        doc.Load(file);
        bool changed = false;
        foreach (var kv in new[] { new[] { "OpenXRRadio", "True" }, new[] { "OpenVRRadio", "False" } })
        {
            var v = doc.SelectSingleNode("//setting[@name='" + kv[0] + "']/value");
            if (v != null && v.InnerText != kv[1]) { v.InnerText = kv[1]; changed = true; }
            if (v == null) { File.WriteAllText(file, InjectorConfigTemplate); return; }
        }
        if (changed) doc.Save(file);
    }

    // ---- start suspended, LoadLibrary the early DLL, resume ----
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, UIntPtr size, uint type, uint prot);
    [DllImport("kernel32", SetLastError = true)] static extern bool WriteProcessMemory(IntPtr p, IntPtr a, byte[] buf, UIntPtr size, IntPtr written);
    [DllImport("kernel32", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr mod, string name);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32", SetLastError = true)] static extern IntPtr CreateRemoteThread(IntPtr p, IntPtr a, UIntPtr stack, IntPtr start, IntPtr param, uint flags, IntPtr id);
    [DllImport("kernel32")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32")] static extern uint ResumeThread(IntPtr h);
    [DllImport("kernel32")] static extern bool TerminateProcess(IntPtr p, uint code);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32")] static extern bool SetProcessDPIAware();

    public static int StartWithDll(string exe, string dll, string args)
    {
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        var cmd = new StringBuilder("\"" + exe + "\" " + args);
        if (!CreateProcessW(exe, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x4 /*CREATE_SUSPENDED*/, IntPtr.Zero,
                Path.GetDirectoryName(exe), ref si, out pi))
            throw new Exception("CreateProcess failed: " + Marshal.GetLastWin32Error());
        byte[] path = Encoding.Unicode.GetBytes(dll + "\0");
        IntPtr mem = VirtualAllocEx(pi.hProcess, IntPtr.Zero, (UIntPtr)path.Length, 0x3000, 0x04);
        bool ok = mem != IntPtr.Zero && WriteProcessMemory(pi.hProcess, mem, path, (UIntPtr)path.Length, IntPtr.Zero);
        IntPtr thread = ok ? CreateRemoteThread(pi.hProcess, IntPtr.Zero, UIntPtr.Zero,
            GetProcAddress(GetModuleHandleW("kernel32.dll"), "LoadLibraryW"), mem, 0, IntPtr.Zero) : IntPtr.Zero;
        if (thread == IntPtr.Zero)
        {
            int err = Marshal.GetLastWin32Error();
            TerminateProcess(pi.hProcess, 1);
            throw new Exception("DLL injection failed: " + err);
        }
        WaitForSingleObject(thread, 10000);
        ResumeThread(pi.hThread);
        CloseHandle(thread); CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
        return pi.dwProcessId;
    }

    // ---- Start ----
    public static int Launch(string gameExe, bool windowed, bool globalPlugins)
    {
        string injector = Path.Combine(Here, @"UEVR\UEVRInjector.exe");
        string earlyDll = Path.Combine(Here, @"gameinput_vr\gameinput_vr.dll");
        foreach (var f in new[] { injector, earlyDll })
            if (!File.Exists(f)) throw new Exception("Missing: " + f);

        // UEVR profile (the mod's scripts) -> %APPDATA%\UnrealVRMod\<exe name>, e.g. GoWEDay-Steam
        string exeName = Path.GetFileName(gameExe);
        string profileDst = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "UnrealVRMod", Path.GetFileNameWithoutExtension(gameExe));
        string profileSrc = Path.Combine(Here, "profile");
        if (!File.Exists(Path.Combine(profileDst, @"scripts\fp.lua")) && Directory.Exists(profileSrc))
        {
            if (MessageBox.Show("The mod profile is not installed. Copy it to:\n" + profileDst + " ?", "GoW E-Day VR",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                CopyDir(profileSrc, profileDst);
        }

        // Flag file read by our patched UEVR: present = also load plugins from UnrealVRMod\UEVR\plugins
        string flag = Path.Combine(profileDst, "load_global_plugins");
        if (globalPlugins) { Directory.CreateDirectory(profileDst); File.WriteAllText(flag, ""); }
        else if (File.Exists(flag)) File.Delete(flag);

        ForceOpenXR(injector);

        if (Process.GetProcessesByName("vrserver").Length == 0)
            Process.Start("steam://rungameid/250820"); // SteamVR

        if (IsSteamCopy(gameExe))
        {
            // Started directly, the game asks Steam to relaunch with an internal AppID; steam_appid.txt avoids that.
            string appid = Path.Combine(Path.GetDirectoryName(gameExe), "steam_appid.txt");
            if (!File.Exists(appid)) File.WriteAllText(appid, "3010850\r\n");
            Environment.SetEnvironmentVariable("SteamAppId", "3010850");
        }

        // Epic anti-cheat with the "null" client: no Easy Anti-Cheat, offline only (campaign). Inherited by the game.
        Environment.SetEnvironmentVariable("EOS_USE_ANTICHEATCLIENTNULL", "1");

        // gameinput_vr.dll must be in before the engine starts (virtual gamepad fed by UEVR).
        int pid = StartWithDll(gameExe, earlyDll, WindowArgs(windowed));

        foreach (var p in Process.GetProcessesByName("UEVRInjector")) { try { p.Kill(); p.WaitForExit(3000); } catch { } }
        Process.Start(new ProcessStartInfo(injector, "--attach=" + exeName) { WorkingDirectory = Path.GetDirectoryName(injector) });
        return pid;
    }

    // ---- keep the game in the foreground: a windowed game without focus pauses itself,
    // and the UEVR menu pointer only hovers/clicks while the game window is the foreground window ----
    [DllImport("user32")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32")] static extern bool AttachThreadInput(int from, int to, bool attach);
    [DllImport("user32")] static extern bool AllowSetForegroundWindow(int pid);
    [DllImport("kernel32")] static extern int GetCurrentThreadId();

    public static IntPtr GameWindow(int pid)
    {
        try { var p = Process.GetProcessById(pid); p.Refresh(); return p.HasExited ? IntPtr.Zero : p.MainWindowHandle; }
        catch { return IntPtr.Zero; }
    }

    public static void FocusWindow(IntPtr h, int pid)
    {
        AllowSetForegroundWindow(pid);
        if (IsIconic(h)) ShowWindow(h, 9 /*SW_RESTORE*/);
        if (SetForegroundWindow(h) && GetForegroundWindow() == h) return;
        // lost the foreground right: borrow it from the thread that has it
        int ignored, fg = GetWindowThreadProcessId(GetForegroundWindow(), out ignored), me = GetCurrentThreadId();
        AttachThreadInput(me, fg, true);
        BringWindowToTop(h);
        SetForegroundWindow(h);
        AttachThreadInput(me, fg, false);
    }

    static void CopyDir(string src, string dst)
    {
        foreach (var d in Directory.GetDirectories(src, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(dst + d.Substring(src.Length));
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
            File.Copy(f, dst + f.Substring(src.Length), true);
    }

    static int SelfTest()
    {
        Func<bool, string, int> check = (ok, what) => { Console.WriteLine((ok ? "ok   " : "FAIL ") + what); return ok ? 0 : 1; };
        int fails = 0;
        fails += check(InjectorConfigDir(@"C:\GoWEDay_VR\UEVR\UEVRInjector.exe").Contains("UEVRInjector_Path_0abaopj32tzl0enxn0dx2bt34u3esqjz"), "injector config hash");
        // a real install is checked only when it exists (set GOW_GAME_DIR to yours)
        string root = Environment.GetEnvironmentVariable("GOW_GAME_DIR") ?? @"C:\Program Files (x86)\Steam\steamapps\common\GoWEDay", game = root + @"\" + ExeRel;
        if (File.Exists(game))
        {
            fails += check(FindGameExe(root) == game, "root folder -> exe");
            fails += check(FindGameExe(root + @"\") == game, "root folder with trailing slash -> exe");
            fails += check(FindGameExe(game) == game, "exe path -> exe");
            fails += check(FindGameExe(root + @"\start_protected_game.exe") == game, "start_protected_game.exe -> real exe");
            fails += check(FindGameExe(Path.GetDirectoryName(game)) == game, "Win64 folder -> exe");
        }
        fails += check(FindGameExe(@"C:\NotTheGame") == null && FindGameExe("") == null, "bad path -> null");
        fails += check(IsSteamCopy(game), "steam copy detected");

        // fake Xbox-app style install in a folder with any name (empty files)
        string x = Path.Combine(Path.GetTempPath(), "gow test " + Guid.NewGuid().ToString("N").Substring(0, 6)), c = Path.Combine(x, "Content");
        string xgame = Path.Combine(c, @"FairlightConcept\Binaries\WinGDK\GoWEDay-WinGDK-Shipping.exe");
        foreach (var f in new[] { xgame, Path.Combine(c, "gamelaunchhelper.exe"), Path.Combine(c, @"Engine\Binaries\Win64\EpicWebHelper.exe"),
                                  Path.Combine(c, @"Engine\Binaries\Win64\CrashReportClient.exe"), Path.Combine(c, @"EasyAntiCheat\EasyAntiCheat_EOS_Setup.exe") })
        { Directory.CreateDirectory(Path.GetDirectoryName(f)); File.WriteAllText(f, ""); }
        string renamed = Path.Combine(Path.GetDirectoryName(xgame), "Gears.exe");
        try
        {
            fails += check(FindGameExe(x) == xgame, "xbox: any-named folder above Content -> game exe");
            fails += check(FindGameExe(c + @"\") == xgame, "xbox: Content folder -> game exe");
            fails += check(FindGameExe(Path.Combine(c, "gamelaunchhelper.exe")) == xgame, "xbox: gamelaunchhelper.exe -> game exe");
            fails += check(FindGameExe(xgame) == xgame, "xbox: exe given -> used as is");
            File.WriteAllText(renamed, "");
            fails += check(FindGameExe(renamed) == renamed, "exe with another name given -> used as is");
            fails += check(!IsSteamCopy(xgame), "xbox copy is not steam");
        }
        finally { Directory.Delete(x, true); }
        fails += check(WindowArgs(true) == "-windowed", "windowed args");
        fails += check(WindowArgs(false) == "-fullscreen", "fullscreen args");
        return fails;
    }
}

class LauncherForm : Form
{
    readonly TextBox folder = new TextBox();
    readonly CheckBox windowed = new CheckBox { Text = "Windowed", AutoSize = true };
    readonly CheckBox globalPlugins = new CheckBox { Text = "Load global UEVR plugins (only if you use plugins from other UEVR mods)", AutoSize = true };

    public LauncherForm()
    {
        Text = "Gears of War: E-Day VR";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); // the icon csc embedded (tools\launcher\icon.ico)
        FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
        ClientSize = new Size(520, 170);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9f);

        var lbl1 = new Label { Text = "Game folder or game exe (Steam or Xbox app):", Location = new Point(12, 12), AutoSize = true };
        folder.SetBounds(12, 34, 400, 24);
        var browse = new Button { Text = "Browse...", Location = new Point(420, 32), Size = new Size(88, 27) };
        var start = new Button { Text = "Start", Location = new Point(388, 120), Size = new Size(120, 36), Font = new Font("Segoe UI", 11f, FontStyle.Bold) };
        var note = new Label { Text = "Campaign only", Location = new Point(12, 135), AutoSize = true, ForeColor = Color.DarkRed };
        var kofi = new LinkLabel { Text = "Support the mod on Ko-fi", Location = new Point(130, 135), AutoSize = true };
        kofi.LinkClicked += (s, e) => Process.Start("https://ko-fi.com/rockonthehill");
        windowed.Location = new Point(12, 70);
        globalPlugins.Location = new Point(12, 94);
        Controls.AddRange(new Control[] { lbl1, folder, browse, windowed, globalPlugins, start, note, kofi });
        AcceptButton = start;

        var cfg = Launcher.LoadSettings();
        string v;
        folder.Text = cfg.TryGetValue("GameFolder", out v) ? v : "";
        windowed.Checked = cfg.TryGetValue("Windowed", out v) && v == "True";
        globalPlugins.Checked = cfg.TryGetValue("GlobalPlugins", out v) && v == "True";

        // One file dialog for both: pick the exe, or open the game folder and press Open with the
        // placeholder name (the dialog then returns <folder>\<placeholder>, which does not exist).
        browse.Click += (s, e) =>
        {
            const string pickFolder = "Select this folder";
            using (var dlg = new OpenFileDialog { Title = "Pick the game exe, or open the game folder and press Open",
                       Filter = "Game exe (*.exe)|*.exe", CheckFileExists = false, ValidateNames = false, FileName = pickFolder })
            {
                string cur = folder.Text.Trim().Trim('"');
                if (File.Exists(cur)) { dlg.InitialDirectory = Path.GetDirectoryName(cur); dlg.FileName = Path.GetFileName(cur); }
                else if (Directory.Exists(cur)) dlg.InitialDirectory = cur;
                if (dlg.ShowDialog(this) != DialogResult.OK) return;
                string picked = dlg.FileName;
                folder.Text = File.Exists(picked) || Directory.Exists(picked) ? picked : Path.GetDirectoryName(picked);
            }
        };
        start.Click += (s, e) => OnStart();
    }

    // Stay in the foreground (so we may hand focus over) until the game window exists, focus it, hide,
    // then for 2 minutes take focus back to the game whenever the UEVR injector or this launcher grabs it.
    void WatchFocus(int pid)
    {
        Text = "Starting the game...";
        foreach (Control c in Controls) c.Enabled = false;
        Cursor = Cursors.Default;
        var started = DateTime.Now;
        DateTime? shown = null;
        int me = Process.GetCurrentProcess().Id;
        var timer = new Timer { Interval = 250 };
        timer.Tick += (s, e) =>
        {
            IntPtr game = Launcher.GameWindow(pid);
            if (shown == null)
            {
                if (game != IntPtr.Zero)
                {
                    Launcher.FocusWindow(game, pid);
                    Hide();
                    shown = DateTime.Now;
                }
                else if (DateTime.Now - started > TimeSpan.FromMinutes(5) || !Process.GetProcesses().Any(p => p.Id == pid)) Close();
                return;
            }
            if (DateTime.Now - shown.Value > TimeSpan.FromMinutes(2)) { Close(); return; }
            if (game == IntPtr.Zero) return; // between windows, or the game exited (then the timeout ends us)
            IntPtr fg = Launcher.GetForegroundWindow();
            int fgPid;
            Launcher.GetWindowThreadProcessId(fg, out fgPid);
            if (fg != game && (fg == IntPtr.Zero || fgPid == me ||
                    Process.GetProcessesByName("UEVRInjector").Any(p => p.Id == fgPid)))
                Launcher.FocusWindow(game, pid);
        };
        timer.Start();
    }

    void OnStart()
    {
        string dir = folder.Text.Trim().Trim('"');
        string exe = Launcher.FindGameExe(dir);
        if (exe == null)
        {
            MessageBox.Show(this, "The game exe was not found in:\n" + dir +
                "\n\nPick the folder where Gears of War: E-Day is installed, or the game exe itself.", "GoW E-Day VR", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        try
        {
            Launcher.SaveSettings(dir, windowed.Checked, globalPlugins.Checked);
            Cursor = Cursors.WaitCursor;
            WatchFocus(Launcher.Launch(exe, windowed.Checked, globalPlugins.Checked));
        }
        catch (Exception ex)
        {
            Cursor = Cursors.Default;
            MessageBox.Show(this, ex.Message, "GoW E-Day VR", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
