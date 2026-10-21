using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Jev;

public record WindowFrame(BitmapSource Image, string Version);

public static class WindowCapture
{
    public static async Task<WindowFrame> Read(CancellationToken ct)
    {
        var processes = new[] { "Weixin", "WeChat" }.SelectMany(Process.GetProcessesByName).ToList();
        try
        {
            var windows = processes.Where(p => p.MainWindowHandle != IntPtr.Zero).ToList();
            if (windows.Count != 1) throw new InvalidOperationException(windows.Count == 0 ? "请先登录微信，并打开要读取的聊天窗口。" : "检测到多个微信主窗口，暂不自动选择。请关闭多余窗口或使用截图识别。");
            var process = windows[0]; var handle = process.MainWindowHandle;
            var version = "未知"; try { version = process.MainModule?.FileVersionInfo.FileVersion ?? version; } catch { }
            if (IsIconic(handle)) { ShowWindowAsync(handle, 9); await Task.Delay(300, ct); }
            if (GetForegroundWindow() != handle) { SetForegroundWindow(handle); await Task.Delay(350, ct); }
            if (!IsWindowVisible(handle) || IsIconic(handle) || GetForegroundWindow() != handle)
                throw new InvalidOperationException("Windows 未允许切换到微信。请先把微信置于前台，再回到助手点“窗口识别”。");
            if (!GetClientRect(handle, out var rect)) throw new InvalidOperationException("未能取得微信窗口尺寸。");
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
            if (width < 200 || height < 200 || (long)width * height > 20_000_000) throw new InvalidOperationException("微信窗口过小或尺寸异常，请调整后重试。");
            var origin = new NativePoint(); if (!ClientToScreen(handle, ref origin)) throw new InvalidOperationException("未能定位微信画面。");
            var screenRect = new NativeRect { Left = origin.X, Top = origin.Y, Right = origin.X + width, Bottom = origin.Y + height };
            int screenLeft = GetSystemMetrics(76), screenTop = GetSystemMetrics(77);
            if (screenRect.Left < screenLeft || screenRect.Top < screenTop || screenRect.Right > screenLeft + GetSystemMetrics(78) || screenRect.Bottom > screenTop + GetSystemMetrics(79))
                throw new InvalidOperationException("微信窗口有部分移出了屏幕，请把整个窗口移回屏幕后重试。");
            EnsureUncovered(handle, screenRect);
            var image = CopyPixels(screenRect);
            // A changed foreground window or geometry can turn screen pixels into unrelated content.
            if (GetForegroundWindow() != handle || !GetClientRect(handle, out var after) || after.Right - after.Left != width || after.Bottom - after.Top != height)
                throw new InvalidOperationException("截取时窗口发生变化，请保持微信画面稳定后重试。");
            var afterOrigin = new NativePoint();
            if (!ClientToScreen(handle, ref afterOrigin) || afterOrigin.X != origin.X || afterOrigin.Y != origin.Y)
                throw new InvalidOperationException("微信窗口在截取时移动了，请重试。");
            EnsureUncovered(handle, screenRect);
            return new WindowFrame(image, version);
        }
        finally { foreach (var process in processes) process.Dispose(); }
    }
    private static void EnsureUncovered(IntPtr target, NativeRect region)
    {
        var seen = new HashSet<IntPtr>();
        for (var above = GetWindow(target, 3); above != IntPtr.Zero && seen.Add(above); above = GetWindow(above, 3))
        {
            if (!IsWindowVisible(above) || IsIconic(above)) continue;
            if (DwmGetWindowAttribute(above, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) continue;
            if (!GetWindowRect(above, out var bounds)) continue;
            if (bounds.Left < region.Right && bounds.Right > region.Left && bounds.Top < region.Bottom && bounds.Bottom > region.Top)
                throw new InvalidOperationException("微信画面被其他窗口或弹窗遮挡。请移开遮挡后再点“窗口识别”，避免识别到其他内容。");
        }
    }
    private static BitmapSource CopyPixels(NativeRect rect)
    {
        var screen = GetDC(IntPtr.Zero); if (screen == IntPtr.Zero) throw new InvalidOperationException("屏幕暂不可读取。");
        IntPtr memory = IntPtr.Zero, bitmap = IntPtr.Zero, previous = IntPtr.Zero;
        try
        {
            int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top, stride = checked(width * 4);
            memory = CreateCompatibleDC(screen); if (memory == IntPtr.Zero) throw new InvalidOperationException("无法创建窗口截图缓冲区。");
            var info = new BitmapInfo { Header = new BitmapInfoHeader { Size = (uint)Marshal.SizeOf<BitmapInfoHeader>(), Width = width, Height = -height, Planes = 1, BitCount = 32 } };
            bitmap = CreateDIBSection(screen, ref info, 0, out var bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero) throw new InvalidOperationException("无法创建窗口画面。");
            previous = SelectObject(memory, bitmap);
            if (previous == IntPtr.Zero || previous == new IntPtr(-1) || !BitBlt(memory, 0, 0, width, height, screen, rect.Left, rect.Top, 0x40CC0020))
                throw new InvalidOperationException("窗口画面读取失败，可以使用截图识别或文字粘贴。");
            GdiFlush(); var bytes = new byte[checked(stride * height)]; Marshal.Copy(bits, bytes, 0, bytes.Length);
            var levels = new HashSet<int>();
            for (int i = 0; i < bytes.Length; i += 64) levels.Add(bytes[i] | bytes[i + 1] << 8 | bytes[i + 2] << 16);
            if (levels.Count < 8) throw new InvalidOperationException("微信画面为空或受到画面保护，未继续识别。请保持微信可见，或改用文字粘贴。");
            var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, bytes, stride); image.Freeze(); return image;
        }
        finally
        {
            if (previous != IntPtr.Zero && previous != new IntPtr(-1)) SelectObject(memory, previous);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap); if (memory != IntPtr.Zero) DeleteDC(memory); ReleaseDC(IntPtr.Zero, screen);
        }
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfoHeader { public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, SizeImage; public int XPelsPerMeter, YPelsPerMeter; public uint ColorsUsed, ColorsImportant; }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfo { public BitmapInfoHeader Header; public uint Colors; }
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr hwnd, ref NativePoint point);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfo info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr value);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint operation);
    [DllImport("gdi32.dll")] private static extern bool GdiFlush();
}
