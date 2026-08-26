param(
    [int]$Seconds = 60,
    [int]$Width = 1600,
    [int]$Height = 900
)

# Drives the desktop composition at high frame rate for stream validation:
# WPF renders through D3D on the active adapter, DWM presents at the display
# refresh rate, and Sunshine/DDAPI must keep up. ffplay alone is not a good
# stress test because its SDL software renderer can be the bottleneck.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$window = New-Object Windows.Window
$window.Title = 'Sunshine FPS stress pattern'
$window.Width = $Width
$window.Height = $Height
$window.Topmost = $true
$window.WindowStyle = [Windows.WindowStyle]::None
$window.Background = [Windows.Media.Brushes]::Black

$canvas = New-Object Windows.Controls.Canvas
$window.Content = $canvas

$ellipse = New-Object Windows.Shapes.Ellipse
$ellipse.Width = 260
$ellipse.Height = 260
$ellipse.Fill = [Windows.Media.Brushes]::DeepSkyBlue
$canvas.Children.Add($ellipse) | Out-Null

$tick = 0
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(16)
$timer.Add_Tick({
    $script:tick++
    $x = [math]::Abs((($script:tick * 24) % (2 * ($Width - 260))) - ($Width - 260))
    $y = [math]::Abs((($script:tick * 13) % (2 * ($Height - 260))) - ($Height - 260))
    [Windows.Controls.Canvas]::SetLeft($ellipse, $x)
    [Windows.Controls.Canvas]::SetTop($ellipse, $y)
    $hue = ($script:tick * 2) % 360
    $color = [Windows.Media.Imaging.ColorConvertedBitmap]::new()
    $brush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(($hue % 256), ((255 - $hue) % 256), 128))
    $ellipse.Fill = $brush
})

$timer.Start()
$window.Show()

Start-Sleep -Seconds $Seconds
$timer.Stop()
$window.Close()
