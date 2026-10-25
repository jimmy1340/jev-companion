using System.Runtime.InteropServices.WindowsRuntime;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Jev;

public static class ScreenshotReader
{
    public static async Task<Capture> Read(BitmapSource image)
    {
        if (image.PixelWidth < 100 || image.PixelHeight < 100) throw new InvalidOperationException("截图太小，请截取微信的消息区域。");
        var chinese = OcrEngine.AvailableRecognizerLanguages.FirstOrDefault(language => language.LanguageTag.StartsWith("zh", StringComparison.OrdinalIgnoreCase));
        var engine = (chinese == null ? null : OcrEngine.TryCreateFromLanguage(chinese)) ?? OcrEngine.TryCreateFromUserProfileLanguages()
            ?? throw new InvalidOperationException("Windows 缺少 OCR 识别语言。请在 Windows 语言设置中安装中文的光学字符识别功能，或使用文字粘贴。");
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var scale = Math.Min(1, (double)OcrEngine.MaxImageDimension / Math.Max(converted.PixelWidth, converted.PixelHeight));
        BitmapSource source = scale < 1 ? new TransformedBitmap(converted, new ScaleTransform(scale, scale)) : converted;
        int width = source.PixelWidth, height = source.PixelHeight, stride = width * 4;
        var pixels = new byte[stride * height]; source.CopyPixels(pixels, stride, 0);
        using var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, width, height, BitmapAlphaMode.Ignore);
        bitmap.CopyFromBuffer(pixels.AsBuffer()); var result = await engine.RecognizeAsync(bitmap);
        var messages = new List<ChatMessage>(); double previousBottom = -100; string previousSender = "";
        foreach (var line in result.Lines)
        {
            if (line.Words.Count == 0 || string.IsNullOrWhiteSpace(line.Text) || WeChatReader.LooksLikeTime(line.Text)) continue;
            double left = line.Words.Min(w => w.BoundingRect.Left), right = line.Words.Max(w => w.BoundingRect.Right);
            double top = line.Words.Min(w => w.BoundingRect.Top), bottom = line.Words.Max(w => w.BoundingRect.Bottom);
            int green = 0, samples = 0;
            for (int y = Math.Max(0, (int)top - 5); y < Math.Min(height, (int)bottom + 5); y += 2)
                for (int x = Math.Max(0, (int)left - 10); x < Math.Min(width, (int)right + 10); x += 2)
                { var i = y * stride + x * 4; var b = pixels[i]; var g = pixels[i + 1]; var r = pixels[i + 2]; if ((g > 145 && g > r + 25 && g > b + 35) || (g > 70 && g > r * 1.25 && g > b * 1.35)) green++; samples++; }
            var sender = green > samples * .13 ? "self" : (left < width * .28 && right < width * .93 ? "other" : "unknown");
            if (sender != "unknown" && sender == previousSender && top - previousBottom < Math.Max(8, (bottom - top) * .6) && messages.Count > 0)
                messages[^1] = messages[^1] with { Text = messages[^1].Text + "\n" + line.Text };
            else messages.Add(new ChatMessage($"ocr-{messages.Count}", sender, line.Text));
            previousSender = sender; previousBottom = bottom;
        }
        Contract.ValidateMessages(messages);
        return new Capture("截图聊天（请核对）", "截图识别", messages, "本机 OCR 识别完成。请核对文字和发送方后分析；没有向模型发送截图。", "screenshot");
    }
}
