using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Jev;

public sealed class MainWindow : Window
{
    private Settings settings;
    private Capture capture = Demo();
    private readonly ModelClient client = new();
    private readonly Dictionary<string, Judgment> cards = new();
    private readonly Dictionary<string, string> errors = new();
    private readonly StackPanel rows = new();
    private readonly ScrollViewer scroll = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock heading = Text("演示 · 周末约饭", 23, true);
    private readonly TextBlock status = Text("先设置模型连接，再体验逐条分析。", 12);
    private readonly TextBlock subheading = Text("聊天旁的 Jev 小助手 · Windows 预览版", 12);
    private readonly Button analyze = Button("逐条分析", null, true);
    private readonly Button stop = Button("停止后续", null);
    private readonly Button follow = Button("跟随", null);
    private readonly WrapPanel sourceTools = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private bool busy, reading, stopAfterCurrent, following;
    private int generation, runningIndex = -1;
    private string? consent;
    private DateTime lastAuto = DateTime.MinValue;
    private readonly CancellationTokenSource lifetime = new();
    private bool preferWindowCapture;
    private bool readIncomplete;
    private string lastReaderDiagnostic = "尚未读取微信。";

    public MainWindow()
    {
        try { settings = Settings.Load(); _ = settings.Connection(); }
        catch { settings = new(); status.Text = "原连接配置无法解密，请在设置中重新填写。"; }
        Title = "Jev 伴聊 0.4.1"; Width = 560; Height = Math.Min(850, SystemParameters.WorkArea.Height - 40); MinWidth = 430; MinHeight = Math.Min(620, SystemParameters.WorkArea.Height - 40);
        FontFamily = new FontFamily("Microsoft YaHei UI"); FontSize = 14; Background = Brush("#EDEDED");
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        var root = new DockPanel(); Content = root;
        var header = new StackPanel { Margin = new Thickness(20, 18, 20, 12) };
        DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var titleRow = new DockPanel(); var settingsButton = Button("连接设置", (_, _) => SettingsDialog());
        DockPanel.SetDock(settingsButton, Dock.Right); titleRow.Children.Add(settingsButton);
        var pin = Button("置顶", (_, _) => { Topmost = !Topmost; }); DockPanel.SetDock(pin, Dock.Right); titleRow.Children.Add(pin);
        titleRow.Children.Add(heading); header.Children.Add(titleRow);
        subheading.Foreground = Brush("#858B87"); subheading.Margin = new Thickness(0, 5, 0, 12); header.Children.Add(subheading);
        var tools = sourceTools; header.Children.Add(tools);
        tools.Children.Add(Button("读取微信", async (_, _) => await ReadWechat()));
        tools.Children.Add(Button("窗口识别", async (_, _) => await ReadWindow()));
        tools.Children.Add(Button("截图识别", async (_, _) => await ReadScreenshot()));
        tools.Children.Add(Button("粘贴", (_, _) => PasteDialog()));
        tools.Children.Add(Button("示例", (_, _) => Load(Demo())));
        tools.Children.Add(follow); follow.Click += async (_, _) => await ToggleFollow();
        var footer = new StackPanel { Background = Brush("#F7F7F7"), Margin = new Thickness(0), Orientation = Orientation.Vertical };
        DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var footerRow = new DockPanel { Margin = new Thickness(18, 12, 18, 5) };
        stop.Visibility = Visibility.Collapsed; DockPanel.SetDock(stop, Dock.Right); footerRow.Children.Add(stop); footerRow.Children.Add(analyze);
        footer.Children.Add(footerRow); status.Margin = new Thickness(20, 3, 20, 8); status.TextWrapping = TextWrapping.Wrap; footer.Children.Add(status);
        var note = Text("模型估计供参考，不代表对方真实心理。回复请核对后自行发送。", 11); note.Foreground = Brush("#909691"); note.Margin = new Thickness(20, 0, 20, 12); note.TextWrapping = TextWrapping.Wrap; footer.Children.Add(note);
        scroll.Content = rows; root.Children.Add(scroll);
        analyze.Click += async (_, _) => await Analyze(); stop.Click += (_, _) => { stopAfterCurrent = true; following = false; timer.Stop(); follow.Content = "跟随"; status.Text = "正在完成当前请求，随后停止。"; };
        timer.Tick += async (_, _) => await Tick();
        Closed += (_, _) => { lifetime.Cancel(); timer.Stop(); client.Dispose(); };
        Render();
    }
    internal static Brush Brush(string hex) => (Brush)new BrushConverter().ConvertFromString(hex)!;
    internal static TextBlock Text(string text, double size = 14, bool bold = false) => new() { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, Foreground = Brush("#24322D"), VerticalAlignment = VerticalAlignment.Center };
    internal static Button Button(string text, RoutedEventHandler? click, bool primary = false)
    {
        var button = new Button { Content = text, Padding = new Thickness(12, 7, 12, 7), Margin = new Thickness(0, 0, 6, 0),
            Background = Brush(primary ? "#95EC69" : "#FFFFFF"), Foreground = Brush("#193225"), BorderBrush = Brush("#D8DCDA"),
            FontWeight = primary ? FontWeights.SemiBold : FontWeights.Normal, Cursor = System.Windows.Input.Cursors.Hand };
        if (click != null) button.Click += click; return button;
    }
    private static Capture Demo()
    {
        string[] texts = ["你今天是不是又忘了我跟你说过什么？", "让我先核对一下，不想随口回答。", "那你说。", "你昨天提到周末一起吃饭，希望这次我来安排。", "所以呢？", "我来找两家餐厅，晚上把时间和地址发给你确认。", "别又只说不做。", "好，我现在就查，定好先和你确认。", "这还差不多。"];
        return new Capture("演示 · 周末约饭（虚构）", "", texts.Select((t, i) => new ChatMessage($"demo-{i}", i % 2 == 0 ? "other" : "self", t)).ToList(), "虚构示例，分析需要真实模型连接。", "demo");
    }
    private void Load(Capture value)
    {
        readIncomplete = false;
        if (ReaderState.MustResetVisualContext(value.Source))
        {
            // Pixels do not supply a reliable contact ID. Do not reuse another capture's consent or cards.
            generation++; consent = null; cards.Clear(); errors.Clear(); following = false; timer.Stop(); follow.Content = "跟随";
        }
        var changed = JsonSerializer.Serialize(capture) != JsonSerializer.Serialize(value);
        if (changed) { generation++; consent = null; stopAfterCurrent = busy; }
        if (capture.Title != value.Title || capture.Source != value.Source) { following = false; timer.Stop(); follow.Content = "跟随"; }
        capture = value; heading.Text = capture.Title; subheading.Text = value.Source == "wechat" ? $"微信 {value.Version} · 当前会话" : "聊天旁的 Jev 小助手 · Windows 预览版";
        status.Text = value.Detail; Render();
    }
    private string Key(int index) => Contract.PrefixKey(capture, index, settings.Connection());
    private void Render()
    {
        var oldOffset = scroll.VerticalOffset; rows.Children.Clear();
        for (var i = 0; i < capture.Messages.Count; i++)
        {
            var index = i; var message = capture.Messages[i]; var self = message.Sender == "self";
            var outer = new StackPanel { HorizontalAlignment = self ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                Margin = new Thickness(self ? 58 : 18, 10, self ? 18 : 58, 12), MaxWidth = 410 };
            var who = Button(self ? "我" : message.Sender == "other" ? "对方" : "发送方待确认", (_, _) => EditMessage(index));
            who.FontSize = 11; who.Padding = new Thickness(3); who.Background = Brushes.Transparent; who.BorderThickness = new Thickness(0); who.HorizontalAlignment = self ? HorizontalAlignment.Right : HorizontalAlignment.Left;
            outer.Children.Add(who);
            var content = Text(message.Text, 17); content.TextWrapping = TextWrapping.Wrap;
            outer.Children.Add(new Border { Background = Brush(self ? "#95EC69" : "#FFFFFF"), CornerRadius = new CornerRadius(7), Padding = new Thickness(14, 11, 14, 11), Child = content });
            string key; try { key = Key(i); } catch { key = ""; }
            if (!self)
            {
                if (cards.TryGetValue(key, out var result)) outer.Children.Add(Card(result, i == capture.Messages.Count - 1));
                else
                {
                    var label = busy && i == runningIndex ? "Jev · 正在分析…" : message.Sender == "unknown" ? "先点上方姓名确认发送方" : "Jev · 分析这条";
                    var rowButton = Button(label, async (_, _) => await Analyze(index)); rowButton.IsEnabled = !busy && !reading && !readIncomplete && message.Sender == "other";
                    rowButton.BorderThickness = new Thickness(0); rowButton.Background = Brushes.Transparent; rowButton.FontSize = 12; rowButton.HorizontalAlignment = HorizontalAlignment.Left; outer.Children.Add(rowButton);
                    if (errors.TryGetValue(key, out var error)) { var tip = Text(error, 12); tip.Foreground = Brush("#B45A28"); tip.TextWrapping = TextWrapping.Wrap; outer.Children.Add(tip); }
                }
            }
            rows.Children.Add(outer);
        }
        analyze.IsEnabled = !busy && !reading && !readIncomplete; analyze.Content = busy ? "正在逐条分析…" : "逐条分析";
        sourceTools.IsEnabled = !reading;
        stop.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        scroll.ScrollToVerticalOffset(oldOffset);
    }
    private Border Card(Judgment result, bool latest)
    {
        var panel = new StackPanel(); panel.Children.Add(Text("Jev:", 13, true));
        void Line(string text, bool bold = false) { var t = Text(text, 13, bold); t.TextWrapping = TextWrapping.Wrap; panel.Children.Add(t); }
        Line("当前可能诉求", true);
        foreach (var item in result.Needs.OrderByDescending(n => n.Value).Take(3)) Line($"- {item.Label}：{item.Value:P0}");
        Line(""); Line("是否需要核对先前记录？", true); Line($"- 是：{result.History:P0}    否：{1 - result.History:P0}");
        Line(""); Line("建议动作", true);
        foreach (var item in result.Actions.OrderByDescending(n => n.Value).Take(3)) Line($"- {item.Label}：{item.Value:P0}");
        Line($"\n紧张程度：{result.Tension:0.#} / 10"); Line($"分歧缓解的线索：{result.Settled:P0}");
        var provider = Text(result.Provider + " · 模型估计", 10); provider.TextWrapping = TextWrapping.Wrap; provider.Foreground = Brush("#7F8881"); provider.Margin = new Thickness(0, 8, 0, 0); panel.Children.Add(provider);
        if (latest)
            foreach (var draft in result.Drafts) { Line("\n" + draft); panel.Children.Add(Button("复制回复", (_, _) => { try { Clipboard.SetText(draft); status.Text = "已复制，请核对后到微信自行发送。"; } catch { status.Text = "剪贴板正忙，请稍后再复制。"; } })); }
        if (!string.IsNullOrEmpty(result.Notice)) Line(result.Notice);
        return new Border { Background = Brush("#E2E2E2"), CornerRadius = new CornerRadius(3), Padding = new Thickness(10), Margin = new Thickness(0, 7, 0, 0), Child = panel };
    }
    private bool Confirm()
    {
        var scope = Contract.Hash(capture.Title + "\0" + capture.Source + "\0" + settings.Url + "\0" + settings.Model + "\0" + settings.UseJev + "\0" + settings.RouterProtected + "\0" + settings.JevProtected);
        if (consent == scope) return true;
        if (capture.Source != "demo")
        {
            var target = settings.UseJev ? "TypeSafe / Jev，以及启用的 9Router 回复模型" : "配置的 9Router 及其上游模型";
            if (MessageBox.Show(this, $"将当前聊天中截至所分析消息的文字发送给{target}。\n\n请先核对文字和发送方。聊天原文不会自动保存到本机。是否开始？", "确认分析范围", MessageBoxButton.OKCancel, MessageBoxImage.Information) != MessageBoxResult.OK) return false;
        }
        consent = scope; return true;
    }
    private async Task Analyze(int? only = null, bool automatic = false)
    {
        if (busy || reading) return;
        if (readIncomplete) { status.Text = "本次读取未完成，旧聊天暂不继续分析。请重新读取或载入文字。"; return; }
        try
        {
            var config = settings.Connection();
            if ((!config.UseJev && string.IsNullOrWhiteSpace(config.Model)) || (config.UseJev && string.IsNullOrWhiteSpace(config.JevKey))) { SettingsDialog(); return; }
            if (!Confirm()) return;
            var pending = Enumerable.Range(0, capture.Messages.Count).Where(i => capture.Messages[i].Sender == "other" &&
                (only.HasValue ? i == only.Value : !cards.ContainsKey(Key(i))) && (!automatic || !errors.ContainsKey(Key(i)))).ToList();
            if (pending.Count == 0) { status.Text = "没有待分析的对方消息。未知发送方请先点姓名确认。"; return; }
            var snapshot = capture; var version = generation; busy = true; stopAfterCurrent = false; int done = 0, failed = 0;
            foreach (var index in pending)
            {
                if (stopAfterCurrent || version != generation) break;
                runningIndex = index; var key = Contract.PrefixKey(snapshot, index, config); errors.Remove(key); Render(); status.Text = $"正在分析 {done + 1} / {pending.Count}…";
                try
                {
                    var result = await client.Analyze(config, snapshot, index, lifetime.Token);
                    if (version != generation) break;
                    cards[key] = result;
                }
                catch (OperationCanceledException) { break; }
                catch (Exception e)
                {
                    if (version != generation) break;
                    errors[key] = Friendly(e); failed++;
                    if (errors[key].Contains("HTTP") || errors[key].Contains("连接")) stopAfterCurrent = true;
                }
                done++; Render();
            }
            status.Text = version == generation ? $"本轮完成 {done - failed} 条，失败 {failed} 条。" + (stopAfterCurrent ? "已停止后续请求。" : "") : "会话或配置已变化，旧请求结果已丢弃。";
        }
        catch (Exception e) { status.Text = Friendly(e); }
        finally { busy = false; runningIndex = -1; Render(); }
    }
    private static string Friendly(Exception e) => e is JsonException || e is KeyNotFoundException || e is InvalidOperationException && e.Message.Contains("Json")
        ? "模型返回格式不符合要求，请重试或更换模型。" : e is System.Net.Http.HttpRequestException ? "无法连接模型服务，请检查连接设置及服务是否运行。" : e is TaskCanceledException ? "模型请求超时，请稍后重试。" : e.Message;
    private async Task ReadWechat(bool automatic = false)
    {
        if (reading || busy) return;
        if (preferWindowCapture && !automatic) { await ReadWindow(); return; }
        reading = true; readIncomplete = true; Render(); status.Text = "正在读取当前微信聊天…";
        try
        {
            var next = await WeChatReader.Read(lifetime.Token);
            lastReaderDiagnostic = $"Jev 0.4.1\n只读接口读取成功\n微信版本：{next.Version}\n文字条数：{next.Messages.Count}";
            if (automatic && (next.Title != capture.Title || next.Source != capture.Source)) { following = false; timer.Stop(); follow.Content = "跟随"; consent = null; status.Text = "微信已切换聊天，跟随已暂停，请重新读取。"; return; }
            // Fresh capture invalidates stale results; unchanged prefixes retain their cached cards.
            var oldConsent = consent; var sameConversation = capture.Title == next.Title && capture.Source == next.Source;
            Load(next); if (automatic && sameConversation) consent = oldConsent;
        }
        catch (ReaderUnavailableException e)
        {
            lastReaderDiagnostic = "Jev 0.4.1\n" + (e.Diagnostic?.Summary() ?? e.Message);
            following = false; timer.Stop(); follow.Content = "跟随"; consent = null;
            if (e.CanUseVisual && !automatic)
            {
                preferWindowCapture = true;
                status.Text = "控件读取未成功，正在切换到微信窗口画面识别…";
                try { await CaptureWindowAndRecognize(); }
                catch (OperationCanceledException) { }
                catch (Exception fallback) { lastReaderDiagnostic += "\n窗口识别：" + fallback.GetType().Name; status.Text = Friendly(fallback); }
            }
            else status.Text = automatic ? "微信界面暂不可读，跟随已暂停。请点“窗口识别”读取当前画面。" : e.Message;
        }
        catch (Exception e) { lastReaderDiagnostic = "Jev 0.4.1\n读取异常：" + e.GetType().Name; status.Text = Friendly(e); following = false; timer.Stop(); follow.Content = "跟随"; }
        finally { reading = false; Render(); }
    }
    private async Task ReadWindow(bool reselect = false)
    {
        if (busy || reading) return;
        following = false; timer.Stop(); follow.Content = "跟随"; consent = null; reading = true; readIncomplete = true; Render();
        try { await CaptureWindowAndRecognize(reselect); preferWindowCapture = true; }
        catch (OperationCanceledException) { }
        catch (Exception e) { lastReaderDiagnostic += "\n窗口识别异常：" + e.GetType().Name; status.Text = Friendly(e); }
        finally { reading = false; Render(); }
    }
    private async Task CaptureWindowAndRecognize(bool reselect = false)
    {
        WindowFrame frame;
        lastReaderDiagnostic += "\n阶段：读取微信窗口画面";
        status.Text = "将切换到微信读取当前画面，图片仅在本机处理…";
        // Hide our own floating window so it cannot be mistaken for WeChat pixels.
        Hide();
        try { frame = await WindowCapture.Read(lifetime.Token); }
        finally { if (!lifetime.IsCancellationRequested) { Show(); Activate(); } }
        lastReaderDiagnostic += $"\n画面已取得：{frame.Image.PixelWidth}×{frame.Image.PixelHeight}；微信 {frame.Version}";
        var region = settings.WindowRegion;
        if (reselect || region == null || !region.Fits(frame.Image.PixelWidth, frame.Image.PixelHeight, frame.Version))
        {
            var picker = new RegionSelector(this, frame);
            if (picker.ShowDialog() != true || picker.Selection == null) { status.Text = "已取消窗口识别；没有调用模型。"; return; }
            region = picker.Selection; settings.WindowRegion = region; settings.Save();
        }
        status.Text = "正在本机识别微信消息，暂未调用模型…";
        lastReaderDiagnostic += "\n阶段：本机 OCR";
        var cropped = new CroppedBitmap(frame.Image, new Int32Rect(region.Left, region.Top, region.Width, region.Height)); cropped.Freeze();
        var result = await ScreenshotReader.Read(cropped);
        lastReaderDiagnostic += $"\n窗口画面读取成功\n微信版本：{frame.Version}\n画面尺寸：{frame.Image.PixelWidth}×{frame.Image.PixelHeight}\n消息区尺寸：{region.Width}×{region.Height}\n识别条数：{result.Messages.Count}";
        Load(result with { Title = "微信 · 窗口识别（请核对）", Version = frame.Version, Source = "wechat-screen", Detail = $"已从微信画面识别 {result.Messages.Count} 条。请核对文字和发送方后分析；调整窗口布局后可在连接设置中重选区域。" });
    }
    private async Task ReadScreenshot()
    {
        if (busy || reading) return;
        if (!Clipboard.ContainsImage()) { MessageBox.Show(this, "按 Win + Shift + S，框选微信右侧的聊天消息区域（保留左右气泡），然后回到这里再点“截图识别”。\n\n截图仅在本机识别；请避免包含联系人列表和输入框。", "截图识别"); return; }
        reading = true; readIncomplete = true; Render();
        try { var image = Clipboard.GetImage(); if (image != null) Load(await ScreenshotReader.Read(image)); }
        catch (Exception e) { status.Text = Friendly(e); }
        finally { reading = false; Render(); }
    }
    private async Task ToggleFollow()
    {
        if (following) { timer.Stop(); following = false; follow.Content = "跟随"; return; }
        if (!ReaderState.CanAutomaticallyFollow(capture.Source)) { status.Text = "窗口识别、截图和粘贴暂不自动跟随。新消息到来后点“窗口识别”再次读取。"; return; }
        if (!Confirm()) return; following = true; follow.Content = "停止跟随"; timer.Start(); await Analyze();
    }
    private async Task Tick()
    {
        if (!following || busy || reading) return;
        await ReadWechat(true);
        if (following && DateTime.Now - lastAuto > TimeSpan.FromSeconds(15))
        { lastAuto = DateTime.Now; if (Enumerable.Range(0, capture.Messages.Count).Any(i => capture.Messages[i].Sender == "other" && !cards.ContainsKey(Key(i)) && !errors.ContainsKey(Key(i)))) await Analyze(automatic: true); }
    }
    private void PasteDialog()
    {
        var dialog = Dialog("粘贴聊天", 520, 480); var panel = new StackPanel { Margin = new Thickness(18) }; dialog.Content = panel;
        panel.Children.Add(Text("每行一条：我：…… / 对方：……；无前缀会标为未知。", 12));
        var title = new TextBox { Text = "手动聊天", Margin = new Thickness(0, 10, 0, 10) }; panel.Children.Add(title);
        var input = new TextBox { AcceptsReturn = true, Height = 300, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; panel.Children.Add(input);
        panel.Children.Add(Button("载入聊天", (_, _) => { try { var messages = Contract.ParsePaste(input.Text); Load(new Capture(title.Text.Trim().Length > 0 ? title.Text.Trim() : "手动聊天", "", messages, "已载入文字，请核对后分析。", "manual")); dialog.Close(); } catch (Exception e) { MessageBox.Show(dialog, e.Message); } }, true)); dialog.ShowDialog();
    }
    private void EditMessage(int index)
    {
        if (busy) return; var message = capture.Messages[index]; var dialog = Dialog("核对这条消息", 470, 330); var panel = new StackPanel { Margin = new Thickness(18) }; dialog.Content = panel;
        var role = new ComboBox { ItemsSource = new[] { "对方", "我", "未知" }, SelectedIndex = message.Sender == "other" ? 0 : message.Sender == "self" ? 1 : 2, Margin = new Thickness(0, 0, 0, 12) }; panel.Children.Add(role);
        var input = new TextBox { Text = message.Text, AcceptsReturn = true, Height = 180, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; panel.Children.Add(input);
        panel.Children.Add(Button("保存修正", (_, _) => { if (string.IsNullOrWhiteSpace(input.Text) || input.Text.Length > 6000) return; var updated = capture.Messages.ToList(); updated[index] = message with { Sender = new[] { "other", "self", "unknown" }[role.SelectedIndex], Text = input.Text }; Load(capture with { Messages = updated, Source = "manual", Detail = "已手动修正，自动跟随已停止。" }); dialog.Close(); }, true)); dialog.ShowDialog();
    }
    private Window Dialog(string title, double width, double height) => new() { Title = title, Width = width, Height = Math.Min(height, SystemParameters.WorkArea.Height - 30), Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner, FontFamily = FontFamily, FontSize = 14, Background = Brush("#F5F7F5"), ResizeMode = ResizeMode.CanResize };
    private void SettingsDialog()
    {
        var dialog = Dialog("模型与连接", 590, 680); var panel = new StackPanel { Margin = new Thickness(22) }; dialog.Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var explanation = Text("此客户端不会自动使用开发电脑的账号。密钥由本机 Windows 用户加密保存，安装包不包含任何账号。", 12); explanation.TextWrapping = TextWrapping.Wrap; panel.Children.Add(explanation);
        void Label(string label) { var t = Text(label, 13, true); t.Margin = new Thickness(0, 15, 0, 5); panel.Children.Add(t); }
        Label("分析模式"); var mode = new ComboBox { ItemsSource = new[] { "9Router：分析与回复", "TypeSafe Jev 判断 + 可选 9Router 回复" }, SelectedIndex = settings.UseJev ? 1 : 0 }; panel.Children.Add(mode);
        Label("9Router / 兼容服务地址"); var url = new TextBox { Text = settings.Url }; panel.Children.Add(url);
        var hint = Text("127.0.0.1 指这台 Windows；共用其他电脑需受认证的 HTTPS 地址。", 11); hint.TextWrapping = TextWrapping.Wrap; panel.Children.Add(hint);
        Label("9Router 密钥"); var routerKey = new PasswordBox { Password = Settings.Unprotect(settings.RouterProtected) }; panel.Children.Add(routerKey);
        Label("回复模型（可刷新列表或手动填写）"); var model = new ComboBox { IsEditable = true, Text = settings.Model }; panel.Children.Add(model);
        var test = Text("连接检测只读取模型列表，不发送聊天。", 12); test.TextWrapping = TextWrapping.Wrap;
        var refresh = Button("刷新模型列表", null); refresh.Margin = new Thickness(0, 8, 0, 4); panel.Children.Add(refresh); panel.Children.Add(test);
        refresh.Click += async (_, _) => { refresh.IsEnabled = false; try { var models = await client.Models(new Connection(url.Text, "", routerKey.Password, false, ""), lifetime.Token); model.ItemsSource = models; if (string.IsNullOrWhiteSpace(model.Text) && models.Length > 0) model.SelectedIndex = 0; test.Text = $"连接成功，找到 {models.Length} 个模型；实际可用性以分析请求为准。"; } catch (Exception e) { test.Text = Friendly(e); } finally { refresh.IsEnabled = true; } };
        Label("TypeSafe / Jev 密钥（仅 Jev 模式需要）"); var jevKey = new PasswordBox { Password = Settings.Unprotect(settings.JevProtected) }; panel.Children.Add(jevKey);
        var save = Button("保存连接", (_, _) => { try { if (mode.SelectedIndex == 0 || !string.IsNullOrWhiteSpace(model.Text)) _ = Contract.Endpoint(url.Text, "models"); settings = new Settings { Url = url.Text.Trim(), Model = model.Text.Trim(), UseJev = mode.SelectedIndex == 1, RouterProtected = Settings.Protect(routerKey.Password.Trim()), JevProtected = Settings.Protect(jevKey.Password.Trim()), WindowRegion = settings.WindowRegion }; settings.Save(); generation++; stopAfterCurrent = busy; consent = null; following = false; timer.Stop(); follow.Content = "跟随"; cards.Clear(); errors.Clear(); Render(); status.Text = "连接配置已保存；点击逐条分析进行实际调用。"; dialog.Close(); } catch (Exception e) { test.Text = Friendly(e); } }, true);
        save.Margin = new Thickness(0, 22, 0, 0); panel.Children.Add(save);
        var diagnostics = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) }; panel.Children.Add(diagnostics);
        diagnostics.Children.Add(Button("重选微信消息区域", async (_, _) => { dialog.Close(); await ReadWindow(true); }));
        diagnostics.Children.Add(Button("复制读取诊断", (_, _) => { try { Clipboard.SetText(lastReaderDiagnostic); test.Text = "已复制诊断：仅含版本、控件数量、异常类型和尺寸，不含聊天文字、图片或密钥。"; } catch { test.Text = "剪贴板正忙，请重试。"; } }));
        dialog.ShowDialog();
    }
}
