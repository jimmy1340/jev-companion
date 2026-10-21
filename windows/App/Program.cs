using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Jev;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Contains("--read-wechat"))
        {
            using var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
            try { stdout.Write(JsonSerializer.Serialize(new ReaderReply(WeChatReader.CaptureCurrent(), null, null), Contract.Json)); return 0; }
            catch (ReaderUnavailableException e) { stdout.Write(JsonSerializer.Serialize(new ReaderReply(null, e.Message, e.Diagnostic, e.CanUseVisual), Contract.Json)); return 1; }
            catch (Exception e) { stdout.Write(JsonSerializer.Serialize(new ReaderReply(null, e is InvalidOperationException ? e.Message : "微信只读接口暂不可用。请点“窗口识别”或粘贴。", null), Contract.Json)); return 1; }
        }
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.DispatcherUnhandledException += (_, e) => { MessageBox.Show("操作未完成，请重试或重新打开应用。没有自动发送微信消息。", "Jev 伴聊"); e.Handled = true; };
        if (args.Contains("--uninstall")) { Installer.Uninstall(); return 0; }
        if (args.Contains("--install") || Path.GetFileName(Environment.ProcessPath!).StartsWith("JevCompanion-Setup", StringComparison.OrdinalIgnoreCase))
            return app.Run(Installer.Window());
        using var mutex = new Mutex(true, @"Local\JevCompanionWindows", out bool created);
        if (!created) { MessageBox.Show("Jev 伴聊已经在运行，请切换到现有窗口。", "Jev 伴聊"); return 0; }
        try { return app.Run(new MainWindow()); } finally { mutex.ReleaseMutex(); }
    }
}

internal static class Installer
{
    private static string InstallDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "JevCompanion");
    private static string Executable => Path.Combine(InstallDirectory, "JevCompanion.exe");
    private static string StartShortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Jev 伴聊.lnk");
    private static string DesktopShortcut => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Jev 伴聊.lnk");
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\JevCompanion";
    public static Window Window()
    {
        var window = new Window { Title = "安装 Jev 伴聊", Width = 550, Height = Math.Min(550, SystemParameters.WorkArea.Height - 30), ResizeMode = ResizeMode.CanResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Background = MainWindow.Brush("#F3F6F2"), FontFamily = new System.Windows.Media.FontFamily("Microsoft YaHei UI") };
        var panel = new StackPanel { Margin = new Thickness(30) }; window.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        panel.Children.Add(MainWindow.Text("Jev 伴聊", 29, true));
        var description = MainWindow.Text("Windows 预览版 0.4.1 · x64\n聊天气泡下方的分析与回复助手。", 15); description.Margin = new Thickness(0, 12, 0, 18); panel.Children.Add(description);
        var details = MainWindow.Text("内含运行环境，无需安装 Python、Codex 或 .NET。\n\n新增：控件读取失败时转为微信窗口识别。首次框选消息区后，同尺寸窗口可直接重读；此路径仍需真机验证。\n\n更新保留已有连接配置；安装包不包含账号或密钥。", 13); details.TextWrapping = TextWrapping.Wrap; panel.Children.Add(details);
        var path = MainWindow.Text("安装位置：" + InstallDirectory, 11); path.Margin = new Thickness(0, 16, 0, 14); path.TextWrapping = TextWrapping.Wrap; panel.Children.Add(path);
        var state = MainWindow.Text("仅安装到当前用户，不修改微信。", 12); state.TextWrapping = TextWrapping.Wrap;
        var button = MainWindow.Button("安装并打开", null, true); panel.Children.Add(button); panel.Children.Add(state);
        button.Click += (_, _) =>
        {
            button.IsEnabled = false;
            try
            {
                if (Mutex.TryOpenExisting(@"Local\JevCompanionWindows", out var running)) { running.Dispose(); throw new InvalidOperationException("请先关闭正在运行的 Jev 伴聊，再安装或更新。"); }
                Directory.CreateDirectory(InstallDirectory);
                var staged = Executable + ".new";
                File.Copy(Environment.ProcessPath!, staged, true); File.Move(staged, Executable, true);
                Shortcut(StartShortcut); Shortcut(DesktopShortcut);
                using var key = Registry.CurrentUser.CreateSubKey(UninstallKey);
                key.SetValue("DisplayName", "Jev 伴聊"); key.SetValue("DisplayVersion", "0.4.1"); key.SetValue("Publisher", "Jev Companion Preview");
                key.SetValue("InstallLocation", InstallDirectory); key.SetValue("DisplayIcon", Executable);
                key.SetValue("UninstallString", "\"" + Executable + "\" --uninstall"); key.SetValue("NoModify", 1); key.SetValue("NoRepair", 1);
                Process.Start(new ProcessStartInfo(Executable) { UseShellExecute = true }); window.Close();
            }
            catch (Exception e) { state.Text = "安装未完成：" + e.Message; button.IsEnabled = true; }
        };
        return window;
    }
    private static void Shortcut(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var type = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("Windows 快捷方式组件不可用。");
        dynamic shell = Activator.CreateInstance(type)!;
        try { dynamic shortcut = shell.CreateShortcut(path); try { shortcut.TargetPath = Executable; shortcut.WorkingDirectory = InstallDirectory; shortcut.Description = "Jev 伴聊"; shortcut.Save(); } finally { Marshal.FinalReleaseComObject(shortcut); } }
        finally { Marshal.FinalReleaseComObject(shell); }
    }
    public static void Uninstall()
    {
        if (MessageBox.Show("卸载当前用户的 Jev 伴聊及快捷方式？\n已加密的连接配置会保留，不会修改微信。", "卸载 Jev 伴聊", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        if (Mutex.TryOpenExisting(@"Local\JevCompanionWindows", out var running)) { running.Dispose(); MessageBox.Show("请先关闭 Jev 伴聊，再卸载。"); return; }
        try
        {
            if (File.Exists(StartShortcut)) File.Delete(StartShortcut);
            if (File.Exists(DesktopShortcut)) File.Delete(DesktopShortcut);
            Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
            // The command is constant; file paths travel only as environment data, never executable syntax.
            const string command = "$ErrorActionPreference='Stop'; Wait-Process -Id ([int]$env:JEV_REMOVE_PID) -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $env:JEV_REMOVE_FILE -ErrorAction SilentlyContinue; $d=[IO.Path]::GetDirectoryName($env:JEV_REMOVE_FILE); if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) { Remove-Item -LiteralPath $d }";
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe")) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-Command", command }) info.ArgumentList.Add(argument);
            info.Environment["JEV_REMOVE_PID"] = Environment.ProcessId.ToString(); info.Environment["JEV_REMOVE_FILE"] = Executable;
            Process.Start(info);
        }
        catch { MessageBox.Show("卸载未完整完成。可关闭应用后手动删除：\n" + InstallDirectory); }
    }
}
