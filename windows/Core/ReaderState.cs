namespace Jev;

public record ReaderDiagnostic(string Version, string RootClass, int Nodes, int InputCandidates,
    int MessageLists, bool TraversalIncomplete, string Code)
{
    public string Summary() => $"微信版本：{Version}\n窗口类型：{RootClass}\n控件数：{Nodes}；输入区候选：{InputCandidates}；消息区候选：{MessageLists}\n遍历是否截断：{TraversalIncomplete}\n结果：{Code}";
}
public record ReaderReply(Capture? Capture, string? Error, ReaderDiagnostic? Diagnostic, bool CanUseVisual = false);

public record PixelRegion(int FrameWidth, int FrameHeight, int Left, int Top, int Width, int Height, string Version)
{
    public bool Fits(int width, int height, string version) => FrameWidth == width && FrameHeight == height && Version == version &&
        Left >= 0 && Top >= 0 && Width >= 100 && Height >= 100 &&
        (long)Left + Width <= width && (long)Top + Height <= height;
    public static PixelRegion FromDrag(double x1, double y1, double x2, double y2, double viewWidth, double viewHeight,
        int frameWidth, int frameHeight, string version)
    {
        if (!double.IsFinite(x1 + y1 + x2 + y2 + viewWidth + viewHeight) || viewWidth <= 0 || viewHeight <= 0 || frameWidth <= 0 || frameHeight <= 0)
            throw new InvalidOperationException("选区尺寸无效，请重新框选。");
        int left = (int)Math.Floor(Math.Clamp(Math.Min(x1, x2), 0, viewWidth) * frameWidth / viewWidth);
        int top = (int)Math.Floor(Math.Clamp(Math.Min(y1, y2), 0, viewHeight) * frameHeight / viewHeight);
        int right = (int)Math.Ceiling(Math.Clamp(Math.Max(x1, x2), 0, viewWidth) * frameWidth / viewWidth);
        int bottom = (int)Math.Ceiling(Math.Clamp(Math.Max(y1, y2), 0, viewHeight) * frameHeight / viewHeight);
        var result = new PixelRegion(frameWidth, frameHeight, left, top, Math.Min(frameWidth, right) - left, Math.Min(frameHeight, bottom) - top, version);
        if (!result.Fits(frameWidth, frameHeight, version)) throw new InvalidOperationException("请框选至少 100 × 100 像素的聊天消息区域。");
        return result;
    }
}

public static class ReaderState
{
    public static bool CanAutomaticallyFollow(string source) => source == "wechat";
    public static bool MustResetVisualContext(string source) => source is "wechat-screen" or "screenshot";
}
