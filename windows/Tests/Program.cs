using Jev;
using System.Net;
using System.Text.Json;

var passed = 0;
void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); passed++; Console.WriteLine("PASS: " + name); }
void Reject(Action fn, string name) { bool rejected = false; try { fn(); } catch { rejected = true; } Check(rejected, name); }
var connection = new Connection("http://127.0.0.1:20128/v1", "test-model", "test-secret", false, "");
var capture = new Capture("虚构测试", "", [new("a", "other", "周末一起吃饭吧"), new("b", "self", "好的"), new("c", "other", "我还有个想法")], "", "demo");
var valid = JsonSerializer.Serialize(new { needs = new[] { .7, .2, .1, .05 }, actions = new[] { .1, .3, .2, .25, .05, .1 }, history = .2, settled = .6, tension = 2.5, drafts = new[] { "好，我们具体商量一下。", "你想先定时间还是地点？" } });
if (args.Length == 2 && args[0] == "--emit-payload") { File.WriteAllText(args[1], JsonSerializer.Serialize(ModelClient.RouterPayload(connection with { Model = "ag/gemini-3.8-flash-high" }, capture, 0))); return; }
if (args.Length == 2 && args[0] == "--parse-router") { var parsed = Contract.ParseRouter(File.ReadAllText(args[1]), "live-validation"); Console.WriteLine(JsonSerializer.Serialize(new { success = true, cards = 1, needs = parsed.Needs.Count, actions = parsed.Actions.Count, drafts = parsed.Drafts.Length })); return; }
if (args.Length == 2 && args[0] == "--emit-jev") { File.WriteAllText(args[1], JsonSerializer.Serialize(ModelClient.JevPayload(capture, 0))); return; }
if (args.Length == 2 && args[0] == "--parse-jev") { using var document = JsonDocument.Parse(File.ReadAllText(args[1])); var parsed = Contract.ParseJev(document.RootElement); Console.WriteLine(JsonSerializer.Serialize(new { success = true, cards = 1, needs = parsed.Needs.Count, actions = parsed.Actions.Count, provider = parsed.Provider })); return; }
Check(Contract.Endpoint(connection.BaseUrl, "models").AbsoluteUri == "http://127.0.0.1:20128/v1/models", "loopback endpoint");
Check(Contract.Endpoint("https://example.com/v1/", "chat/completions").Scheme == "https", "authenticated remote HTTPS possible");
Reject(() => Contract.Endpoint("http://192.168.1.3:20128/v1", "models"), "plaintext remote credentials blocked");
Reject(() => Contract.Endpoint("https://user:key@example.com/v1", "models"), "URL credential rejected");
Reject(() => Contract.Endpoint("https://example.com/v1?token=secret", "models"), "URL query rejected");
Reject(() => Contract.Endpoint("https://example.com/v1", "../private"), "endpoint escape rejected");
var messages = Contract.ParsePaste("我：好\n对方:收到\n没标记\n\n");
Check(messages.Select(x => x.Sender).SequenceEqual(new[] { "self", "other", "unknown" }), "unmarked text remains unknown");
Reject(() => Contract.ParsePaste("我："), "empty message rejected");
Reject(() => Contract.ParsePaste("对方：" + new string('a', 6001)), "oversize message rejected");
var extended = capture with { Messages = capture.Messages.Concat(new[] { new ChatMessage("d", "other", "新消息") }).ToList() };
Check(Contract.PrefixKey(capture, 0, connection) == Contract.PrefixKey(extended, 0, connection), "appended messages preserve earlier cache");
Check(Contract.PrefixKey(capture, 0, connection) != Contract.PrefixKey(capture with { Title = "另一个聊天" }, 0, connection), "conversation isolation");
Check(Contract.PrefixKey(capture, 0, connection) != Contract.PrefixKey(capture, 0, connection with { Model = "different" }), "model change invalidates cards");
Check(Contract.PrefixKey(capture, 0, connection) != Contract.PrefixKey(capture, 0, connection with { RouterKey = "new" }), "credentials change invalidates cards");
using (var payload = JsonDocument.Parse(JsonSerializer.Serialize(ModelClient.RouterPayload(connection, capture, 0))))
{
    var data = payload.RootElement.GetProperty("messages")[1].GetProperty("content").GetString()!;
    Check(!data.Contains("我还有个想法") && !data.Contains("好的"), "later messages absent from earlier request");
    Check(!payload.RootElement.ToString().Contains(connection.RouterKey), "secret absent from request payload");
}
var judgment = Contract.ParseRouter(valid, "test");
Check(judgment.Needs.Count == 4 && judgment.Actions.Count == 6 && judgment.Drafts.Length == 2, "typed router response");
Check(Contract.ParseRouter("```json\n" + valid + "\n```", "test").Tension == 2.5, "JSON code fence accepted");
Reject(() => Contract.ParseRouter(valid.Replace("0.7", "1.7"), "test"), "out-of-range probability rejected");
Reject(() => Contract.ParseRouter(valid.Replace("0.25", "0.75"), "test"), "bad action distribution rejected");
Reject(() => Contract.ParseRouter("{}", "test"), "missing results never fabricated");
using (var handler = new FixtureHandler(HttpStatusCode.OK, JsonSerializer.Serialize(new { choices = new[] { new { message = new { content = valid } } } })))
using (var client = new ModelClient(handler))
{
    var card = await client.Analyze(connection, capture, 0, CancellationToken.None);
    Check(card.Provider.Contains("9Router"), "router provenance retained");
    Check(handler.Auth == "Bearer test-secret" && handler.Uri == "http://127.0.0.1:20128/v1/chat/completions", "credential goes only to configured endpoint");
}
using (var handler = new FixtureHandler(HttpStatusCode.Unauthorized, "private error test-secret"))
using (var client = new ModelClient(handler))
{
    string error = ""; try { await client.Analyze(connection, capture, 0, CancellationToken.None); } catch (Exception e) { error = e.Message; }
    Check(error.Contains("401") && !error.Contains("test-secret"), "provider error body never leaked");
}
using (var handler = new FixtureHandler(HttpStatusCode.OK, "{}", true))
using (var client = new ModelClient(handler))
using (var cancel = new CancellationTokenSource(30))
{
    bool canceled = false; try { await client.Analyze(connection, capture, 0, cancel.Token); } catch (OperationCanceledException) { canceled = true; }
    Check(canceled, "network request honors shutdown cancellation");
}
var answers = new Dictionary<string, object>();
foreach (var id in Contract.NeedIds) answers["need_" + id] = new { type = "noul", noul = .5 };
answers["needs_history"] = new { type = "noul", noul = .2 }; answers["settled"] = new { type = "noul", noul = .7 };
answers["next_action"] = new { type = "choice", probabilities = Contract.ActionIds.ToDictionary(x => x, _ => 1.0 / 6) }; answers["tension"] = new { type = "score", score = 1.2 };
using (var jev = JsonDocument.Parse(JsonSerializer.Serialize(new { model = "jev-fixture", answers }))) Check(Contract.ParseJev(jev.RootElement).Tension == 3, "Jev score mapped from 0..4 to 0..10");
var region = PixelRegion.FromDrag(80, 30, 480, 300, 600, 400, 1200, 800, "4.1.15.8");
Check(region.Left == 160 && region.Top == 60 && region.Width == 800 && region.Height == 540, "preview coordinates converted to original image pixels");
Check(region.Fits(1200, 800, "4.1.15.8"), "matching window reuses user selected region");
Check(!region.Fits(1400, 800, "4.1.15.8"), "window resize requires a new selection");
Check(!region.Fits(1200, 800, "4.1.16.1"), "WeChat update invalidates saved region");
Check(!new PixelRegion(1200, 800, int.MaxValue, 0, 500, 500, "v").Fits(1200, 800, "v"), "region overflow rejected");
Check(!new PixelRegion(1200, 800, -1, 0, 500, 500, "v").Fits(1200, 800, "v"), "negative region rejected");
Reject(() => PixelRegion.FromDrag(1, 1, 5, 5, 600, 400, 1200, 800, "v"), "small accidental selection rejected");
Reject(() => PixelRegion.FromDrag(double.NaN, 1, 50, 50, 600, 400, 1200, 800, "v"), "nonfinite selection rejected");
Check(PixelRegion.FromDrag(480, 300, 80, 30, 600, 400, 1200, 800, "4.1.15.8") == region, "reverse direction selection works");
var edge = PixelRegion.FromDrag(-50, -60, 700, 500, 600, 400, 1200, 800, "v");
Check(edge.Left == 0 && edge.Top == 0 && edge.Width == 1200 && edge.Height == 800, "selection stays inside WeChat image");
Check(!ReaderState.CanAutomaticallyFollow("wechat-screen") && !ReaderState.CanAutomaticallyFollow("screenshot"), "unknown visual chat identity cannot enable automatic model calls");
Check(ReaderState.MustResetVisualContext("wechat-screen") && ReaderState.MustResetVisualContext("screenshot"), "each visual read starts a fresh analysis context");
var failure = JsonSerializer.Deserialize<ReaderReply>("{\"Capture\":null,\"Error\":\"未找到聊天区\",\"CanUseVisual\":true}", Contract.Json)!;
Check(failure.Capture == null && failure.CanUseVisual, "missing UIA anchor becomes explicit visual fallback");
var noWindow = new ReaderReply(null, "没有微信窗口", null);
Check(!noWindow.CanUseVisual, "missing target does not trigger another capture");
Console.WriteLine($"{passed} checks passed.");

sealed class FixtureHandler(HttpStatusCode status, string response, bool wait = false) : HttpMessageHandler
{
    public string? Auth; public string? Uri;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    { Auth = request.Headers.Authorization?.ToString(); Uri = request.RequestUri?.AbsoluteUri; if (wait) await Task.Delay(5000, ct); return new HttpResponseMessage(status) { Content = new StringContent(response) }; }
}
