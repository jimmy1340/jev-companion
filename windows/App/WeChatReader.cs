using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Windows.Automation;

namespace Jev;

public sealed class ReaderUnavailableException(string message, ReaderDiagnostic? diagnostic, bool canUseVisual) : InvalidOperationException(message)
{
    public ReaderDiagnostic? Diagnostic { get; } = diagnostic;
    public bool CanUseVisual { get; } = canUseVisual;
}

public static class WeChatReader
{
    private static readonly string[] ProcessNames = ["Weixin", "WeChat"];
    public static async Task<Capture> Read(CancellationToken ct)
    {
        using var worker = new Process { StartInfo = new ProcessStartInfo(Environment.ProcessPath!, "--read-wechat") {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 } };
        worker.Start(); var stdout = worker.StandardOutput.ReadToEndAsync(ct); var stderr = worker.StandardError.ReadToEndAsync(ct);
        try { await worker.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(12), ct); }
        catch
        {
            try { if (!worker.HasExited) worker.Kill(); } catch { }
            ct.ThrowIfCancellationRequested();
            throw new ReaderUnavailableException("微信控件读取超时。", new ReaderDiagnostic("未知", "未知", 0, 0, 0, true, "uia_timeout"), true);
        }
        var output = await stdout; _ = await stderr;
        var reply = JsonSerializer.Deserialize<ReaderReply>(output, Contract.Json) ?? throw new InvalidOperationException("读取结果无效。");
        if (worker.ExitCode != 0 || reply.Capture == null) throw new ReaderUnavailableException(reply.Error ?? "微信读取失败。", reply.Diagnostic, reply.CanUseVisual);
        var capture = reply.Capture;
        Contract.ValidateMessages(capture.Messages); return capture;
    }
    private static bool Aid(string id, string token) => id.Split('.').Contains(token, StringComparer.OrdinalIgnoreCase);
    private static List<AutomationElement> Walk(AutomationElement root, out bool incomplete)
    {
        var result = new List<AutomationElement>(); var pending = new Stack<(AutomationElement, int)>(); pending.Push((root, 0));
        var watch = Stopwatch.StartNew(); var walker = TreeWalker.RawViewWalker; incomplete = false;
        while (pending.Count > 0 && result.Count < 2500 && watch.Elapsed.TotalSeconds < 4)
        {
            var (node, depth) = pending.Pop(); result.Add(node); if (depth > 26) { incomplete = true; continue; }
            var children = new List<AutomationElement>();
            try { for (var child = walker.GetFirstChild(node); child != null && children.Count < 300; child = walker.GetNextSibling(child)) children.Add(child); } catch (ElementNotAvailableException) { }
            if (children.Count >= 300) incomplete = true;
            for (int i = children.Count - 1; i >= 0; i--) pending.Push((children[i], depth + 1));
        }
        incomplete |= pending.Count > 0;
        return result;
    }
    public static Capture CaptureCurrent()
    {
        var processes = ProcessNames.SelectMany(Process.GetProcessesByName).ToList();
        try
        {
            var candidates = processes.Where(p => p.MainWindowHandle != IntPtr.Zero).ToList();
            if (candidates.Count != 1) throw new InvalidOperationException(candidates.Count == 0 ? "未找到可见的微信窗口。请登录微信并打开聊天；最小化或托盘状态可能无法读取。" : "检测到多个微信窗口，请只保留一个可读取的主窗口。");
            var process = candidates[0]; string version = "未知"; try { version = process.MainModule?.FileVersionInfo.FileVersion ?? version; } catch { }
            var root = AutomationElement.FromHandle(process.MainWindowHandle); var nodes = Walk(root, out bool incomplete);
            var rootRect = root.Current.BoundingRectangle;
            var inputs = nodes.Where(n => Aid(n.Current.AutomationId, "chat_input_field")).ToList();
            if (inputs.Count == 0)
                inputs = nodes.Where(n => n.Current.ControlType == ControlType.Edit && !n.Current.IsOffscreen &&
                    n.Current.BoundingRectangle.Width > rootRect.Width * .25 && n.Current.BoundingRectangle.Top > rootRect.Top + rootRect.Height * .5).ToList();
            var messageLists = nodes.Where(n => Aid(n.Current.AutomationId, "chat_message_list") || n.Current.ClassName == "mmui::RecyclerListView").ToList();
            var diagnostic = new ReaderDiagnostic(version, root.Current.ClassName, nodes.Count, inputs.Count, messageLists.Count, incomplete, "uia_missing_input");
            // Missing one anchor is not evidence that WeChat exposes no accessibility content.
            if (inputs.Count != 1) throw new ReaderUnavailableException("未能唯一定位微信聊天输入区，将尝试窗口画面识别。", diagnostic, true);
            var input = inputs[0];
            var inputRect = input.Current.BoundingRectangle;
            var lists = messageLists
                .Where(n => { var r = n.Current.BoundingRectangle; return !r.IsEmpty && r.Width > 200 && r.Right > inputRect.Left + 150 && r.Left >= inputRect.Left - 80 && r.Top < inputRect.Top; })
                .OrderByDescending(n => n.Current.BoundingRectangle.Width * n.Current.BoundingRectangle.Height).ToList();
            if (lists.Count == 0) throw new ReaderUnavailableException("未能定位微信消息列表，将尝试窗口画面识别。", diagnostic with { Code = "uia_missing_list" }, true);
            var list = lists[0]; var bounds = list.Current.BoundingRectangle; var rows = new List<ChatMessage>();
            var walker = TreeWalker.ControlViewWalker;
            for (var row = walker.GetFirstChild(list); row != null && rows.Count < 200; row = walker.GetNextSibling(row))
            {
                var parts = Walk(row, out _).Where(n => n.Current.ControlType == ControlType.Text && !string.IsNullOrWhiteSpace(n.Current.Name) && !n.Current.IsOffscreen).ToList();
                if (parts.Count == 0) continue;
                var body = parts.OrderByDescending(n => n.Current.Name.Length).First(); var r = body.Current.BoundingRectangle;
                var value = body.Current.Name.Trim(); if (value.Length == 0 || value.Length > 6000 || LooksLikeTime(value)) continue;
                string sender = "unknown";
                if (r.Width < bounds.Width * .60) { if (r.Left - bounds.Left < 95) sender = "other"; else if (bounds.Right - r.Right < 95) sender = "self"; }
                rows.Add(new ChatMessage("uia-" + string.Join('-', row.GetRuntimeId()), sender, value));
            }
            if (rows.Count == 0) throw new ReaderUnavailableException("消息区暂未读到文字，将尝试窗口画面识别。", diagnostic with { Code = "uia_no_text" }, true);
            var title = input.Current.Name.Trim(); if (string.IsNullOrEmpty(title)) title = "当前微信聊天（请核对）";
            return new Capture(title, version, rows, $"只读接口 · {rows.Count} 条 · 4.1.15.8 待真机验证。请核对发送方，点击姓名可修正。");
        }
        finally { foreach (var p in processes) p.Dispose(); }
    }
    internal static bool LooksLikeTime(string text) => System.Text.RegularExpressions.Regex.IsMatch(text, @"^(今天|昨天|星期[一二三四五六日天])?\s*\d{1,2}:\d{2}$");
}
