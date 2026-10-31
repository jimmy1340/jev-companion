using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Jev;

public record ChatMessage(string Id, string Sender, string Text);
public record Capture(string Title, string Version, List<ChatMessage> Messages, string Detail, string Source = "wechat");
public record Probability(string Label, double Value);
public record Judgment(List<Probability> Needs, List<Probability> Actions, double History, double Settled,
    double Tension, string[] Drafts, string Provider, string Notice = "");
public record Connection(string BaseUrl, string Model, string RouterKey, bool UseJev, string JevKey);

public static class Contract
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    public static readonly string[] NeedLabels = ["希望被认真回应", "希望确认先前的事情", "希望落实下一步", "希望暂停或留出空间"];
    public static readonly string[] ActionLabels = ["先核对聊天原文", "温和确认具体所指", "先回应对方的表达", "一起确认下一步", "简短回应后暂停", "信息不足，先确认"];
    public static readonly string[] NeedIds = ["attention", "recall", "action", "space"];
    public static readonly string[] ActionIds = ["search_history", "clarify", "acknowledge", "propose_next_step", "pause", "unknown"];
    public static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    public static string PrefixKey(Capture capture, int index, Connection config) => Hash(JsonSerializer.Serialize(new {
        capture.Title, capture.Source, messages = capture.Messages.Take(index + 1), config.BaseUrl,
        config.Model, config.UseJev, routerCredential = Hash(config.RouterKey), jevCredential = Hash(config.JevKey)
    }));
    public static string? SecretIssue(string? key, bool required)
    {
        if (string.IsNullOrWhiteSpace(key))
            return required ? "尚未填写。请使用这台电脑自己的密钥；安装包不含开发者账号，也不会读取其他工具保存的密钥。" : null;
        var trimmed = key.Trim();
        if (trimmed.Length >= 2 && ((trimmed[0] == '"' && trimmed[^1] == '"') || (trimmed[0] == '\'' && trimmed[^1] == '\'')))
            return "不要带两侧引号。粘贴密钥本身即可，密钥不会显示在错误里。";
        if (trimmed.Length > 8192 || trimmed.Any(c => c < 33 || c > 126))
            return "格式不正确。请使用一行可打印字符，不要包含空格或换行。";
        return null;
    }
    public static string RequireSecret(string? key, string label)
    {
        var issue = SecretIssue(key, true);
        if (issue != null) throw new InvalidOperationException(label + issue);
        return key!.Trim();
    }
    public static string? OptionalSecret(string? key, string label)
    {
        var issue = SecretIssue(key, false);
        if (issue != null) throw new InvalidOperationException(label + issue);
        return string.IsNullOrWhiteSpace(key) ? null : key.Trim();
    }
    public static void ValidateConnectionDraft(bool useJev, string? url, string? model, string? routerKey, string? jevKey)
    {
        var routerIssue = SecretIssue(routerKey, false);
        if (routerIssue != null) throw new InvalidOperationException("9Router 密钥" + routerIssue);
        if (useJev)
        {
            var jevIssue = SecretIssue(jevKey, true);
            if (jevIssue != null) throw new InvalidOperationException("TypeSafe / Jev 密钥" + jevIssue);
        }
        var modelText = (model ?? "").Trim();
        if (!useJev || modelText.Length > 0)
        {
            Endpoint(url ?? "", "models");
            if (!useJev && modelText.Length == 0)
                throw new InvalidOperationException("9Router 模式需要填写或从列表选择回复模型。可先刷新模型列表；服务不需要认证时密钥留空。");
        }
    }
    public static string DescribeHttpStatus(int status, bool sentCredential)
    {
        if (status is 401 or 403)
            return sentCredential
                ? $"模型服务拒绝了当前密钥（HTTP {status}）。请在连接设置核对本机保存的密钥；安装包不会带入其他电脑或开发者的账号。"
                : $"模型服务要求密钥（HTTP {status}），本次没有附带。不需要认证时可留空；需要时填写这台电脑的密钥，不要把密钥写进地址。";
        if (status == 404)
            return "模型服务返回 HTTP 404。地址需要以 /v1 结尾，例如 http://127.0.0.1:20128/v1。127.0.0.1 指运行 Jev 的这台电脑。";
        if (status is 429 or 529)
            return $"模型服务当前限流（HTTP {status}），请稍后手动重试。没有生成推测结果。";
        return $"模型服务返回 HTTP {status}；检查连接、密钥、模型或额度。没有生成推测结果。";
    }
    public static string ConnectionFailureHint(string? baseUrl)
    {
        var loopback = !string.IsNullOrWhiteSpace(baseUrl) && Uri.TryCreate(baseUrl.Trim(), UriKind.Absolute, out var url) && url.IsLoopback;
        return loopback
            ? "无法连接本机模型服务。127.0.0.1 指运行 Jev 的这台电脑，请确认兼容服务已启动。没有发送聊天。"
            : "无法连接模型服务。请检查 HTTPS 地址和网络。没有发送聊天。";
    }
    public static string StartupHint(bool settingsFileExists, bool useJev, bool hasJevKey, bool hasModel)
    {
        if (!settingsFileExists)
            return "第一次使用：打开「连接设置」，填写这台电脑自己的 TypeSafe 或 9Router 信息。安装包不含开发者密钥。示例已载入，点击分析才会调用模型。";
        if (useJev && !hasJevKey)
            return "已选择 Jev 判断，但还没有保存 TypeSafe 密钥。请在连接设置填写这台电脑的密钥；不会使用其他电脑的账号。";
        if (!useJev && !hasModel)
            return "9Router 模式还没有回复模型。打开连接设置，确认地址后刷新列表并保存。不需要认证时密钥留空。";
        return "示例已载入。点击逐条分析才会调用模型；请确认连接设置里是这台电脑的密钥。";
    }
    public static Uri Endpoint(string input, string path)
    {
        if (!Uri.TryCreate(input.Trim().TrimEnd('/'), UriKind.Absolute, out var url) ||
            !string.IsNullOrEmpty(url.UserInfo) || !string.IsNullOrEmpty(url.Query) || !string.IsNullOrEmpty(url.Fragment) ||
            url.AbsolutePath.TrimEnd('/') != "/v1" ||
            !(url.Scheme == "https" || (url.Scheme == "http" && url.IsLoopback)))
            throw new InvalidOperationException("填写以 /v1 结尾的 HTTPS 服务地址；本机 127.0.0.1 可用 HTTP。其他电脑不能用这个地址连接你的 Mac。");
        if (path != "models" && path != "chat/completions") throw new InvalidOperationException("接口不受支持。");
        return new Uri(url.AbsoluteUri.TrimEnd('/') + "/" + path);
    }
    public static List<ChatMessage> ParsePaste(string text)
    {
        var result = new List<ChatMessage>();
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(raw)) continue;
            var line = raw.Trim(); string sender; string content;
            if (line.StartsWith("我：") || line.StartsWith("我:")) { sender = "self"; content = line[2..]; }
            else if (line.StartsWith("对方：") || line.StartsWith("对方:")) { sender = "other"; content = line[3..]; }
            else { sender = "unknown"; content = line; }
            if (string.IsNullOrWhiteSpace(content)) continue;
            result.Add(new ChatMessage($"paste-{result.Count}", sender, content));
        }
        ValidateMessages(result); return result;
    }
    public static void ValidateMessages(IReadOnlyList<ChatMessage> messages)
    {
        if (messages.Count is < 1 or > 200 || messages.Sum(m => m.Text.Length) > 60000 ||
            messages.Any(m => string.IsNullOrWhiteSpace(m.Text) || m.Text.Length > 6000 ||
                (m.Sender != "self" && m.Sender != "other" && m.Sender != "unknown")))
            throw new InvalidOperationException("请提供 1–200 条文字，每条不超过 6000 字，总计不超过 60000 字。");
    }
    public static double Number(JsonElement element, double max = 1)
    {
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetDouble(out var n) || !double.IsFinite(n) || n < 0 || n > max)
            throw new InvalidOperationException("模型返回了无效数值，未生成分析卡。");
        return n;
    }
    public static Judgment ParseRouter(string text, string model)
    {
        text = text.Trim();
        if (text.StartsWith("```")) { var start = text.IndexOf('\n'); var end = text.LastIndexOf("```"); if (start >= 0 && end > start) text = text[(start + 1)..end]; }
        using var doc = JsonDocument.Parse(text); var r = doc.RootElement;
        List<Probability> ReadArray(string name, string[] labels, bool sum)
        {
            var values = r.GetProperty(name).EnumerateArray().Select(e => Number(e)).ToArray();
            if (values.Length != labels.Length || (sum && Math.Abs(values.Sum() - 1) > .02)) throw new InvalidOperationException("模型返回的概率分布不完整，请重试。");
            return values.Select((v, i) => new Probability(labels[i], v)).ToList();
        }
        var needs = ReadArray("needs", NeedLabels, false); var actions = ReadArray("actions", ActionLabels, true);
        var drafts = r.GetProperty("drafts").EnumerateArray().Select(e => e.GetString() ?? "").ToArray();
        if (drafts.Length != 2 || drafts.Any(d => string.IsNullOrWhiteSpace(d) || d.Length > 1200)) throw new InvalidOperationException("模型没有返回两条有效回复。");
        return new(needs, actions, Number(r.GetProperty("history")), Number(r.GetProperty("settled")),
            Number(r.GetProperty("tension"), 10), drafts, "9Router · " + model);
    }
    public static Judgment ParseJev(JsonElement root)
    {
        var answers = root.GetProperty("answers");
        JsonElement Answer(string id, string type)
        { var a = answers.GetProperty(id); if (a.GetProperty("type").GetString() != type) throw new InvalidOperationException("Jev 判断类型不完整。"); return a; }
        var needs = NeedIds.Select((id, i) => new Probability(NeedLabels[i], Number(Answer("need_" + id, "noul").GetProperty("noul")))).ToList();
        var action = Answer("next_action", "choice"); var values = action.GetProperty("probabilities");
        if (values.EnumerateObject().Count() != ActionIds.Length) throw new InvalidOperationException("Jev 动作分布不完整。");
        var actions = ActionIds.Select((id, i) => new Probability(ActionLabels[i], Number(values.GetProperty(id)))).ToList();
        if (Math.Abs(actions.Sum(x => x.Value) - 1) > .02) throw new InvalidOperationException("Jev 动作概率无效。");
        var tension = Number(Answer("tension", "score").GetProperty("score"), 4) * 2.5;
        return new(needs, actions, Number(Answer("needs_history", "noul").GetProperty("noul")),
            Number(Answer("settled", "noul").GetProperty("noul")), tension, [], "Jev · " + root.GetProperty("model").GetString());
    }
}
