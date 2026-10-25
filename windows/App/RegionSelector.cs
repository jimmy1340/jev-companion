using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Jev;

public sealed class RegionSelector : Window
{
    public PixelRegion? Selection { get; private set; }
    public RegionSelector(Window owner, WindowFrame frame)
    {
        Title = "框选微信消息区域"; Owner = owner; FontFamily = owner.FontFamily; Background = MainWindow.Brush("#F5F5F7");
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize;
        var scale = Math.Min(1, Math.Min((SystemParameters.WorkArea.Width - 90) / frame.Image.PixelWidth, (SystemParameters.WorkArea.Height - 190) / frame.Image.PixelHeight));
        var width = frame.Image.PixelWidth * scale; var height = frame.Image.PixelHeight * scale;
        Width = width + 48; Height = height + 155;
        var root = new DockPanel { Margin = new Thickness(16) }; Content = root;
        var footer = new StackPanel { Margin = new Thickness(0, 10, 0, 0) }; DockPanel.SetDock(footer, Dock.Bottom); root.Children.Add(footer);
        var note = MainWindow.Text("拖动框选右侧消息区，保留左右气泡；排除联系人列表、标题和输入框。", 12); note.TextWrapping = TextWrapping.Wrap; footer.Children.Add(note);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) }; footer.Children.Add(buttons);
        var accept = MainWindow.Button("记住区域并识别", (_, _) => { if (Selection != null) DialogResult = true; }, true); accept.IsEnabled = false; buttons.Children.Add(accept);
        buttons.Children.Add(MainWindow.Button("取消", (_, _) => { DialogResult = false; }));
        var canvas = new Canvas { Width = width, Height = height, Background = Brushes.Transparent, Cursor = Cursors.Cross, ClipToBounds = true };
        root.Children.Add(canvas);
        canvas.Children.Add(new Image { Source = frame.Image, Width = width, Height = height, Stretch = Stretch.Fill, IsHitTestVisible = false });
        var rectangle = new Rectangle { Stroke = MainWindow.Brush("#0A84FF"), StrokeThickness = 2, Fill = new SolidColorBrush(Color.FromArgb(46, 10, 132, 255)), IsHitTestVisible = false }; canvas.Children.Add(rectangle);
        Point? start = null;
        void Update(Point point)
        {
            if (start == null) return; var a = start.Value;
            var x1 = Math.Clamp(a.X, 0, width); var y1 = Math.Clamp(a.Y, 0, height); var x2 = Math.Clamp(point.X, 0, width); var y2 = Math.Clamp(point.Y, 0, height);
            Canvas.SetLeft(rectangle, Math.Min(x1, x2)); Canvas.SetTop(rectangle, Math.Min(y1, y2)); rectangle.Width = Math.Abs(x1 - x2); rectangle.Height = Math.Abs(y1 - y2);
            try { Selection = PixelRegion.FromDrag(x1, y1, x2, y2, width, height, frame.Image.PixelWidth, frame.Image.PixelHeight, frame.Version); accept.IsEnabled = true; }
            catch { Selection = null; accept.IsEnabled = false; }
        }
        canvas.MouseLeftButtonDown += (_, e) => { start = e.GetPosition(canvas); canvas.CaptureMouse(); Update(start.Value); };
        canvas.MouseMove += (_, e) => { if (canvas.IsMouseCaptured) Update(e.GetPosition(canvas)); };
        canvas.MouseLeftButtonUp += (_, e) => { Update(e.GetPosition(canvas)); canvas.ReleaseMouseCapture(); start = null; };
    }
}
