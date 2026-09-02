# Desktop HUD: per-virtual-desktop context overlay.
# Shows a transient HUD (desktop name + theme + tasks) whenever you switch virtual desktops,
# plus an optional tiny always-visible "anchor pill". Notes are keyed by desktop GUID.
# Built on stable surfaces only: VirtualDesktops registry + documented IVirtualDesktopManager COM.
#
# Hotkeys:  Win+Shift+N edit note   Win+Shift+H replay HUD   Win+Shift+B toggle pill
# Usage:    DesktopHud.bat (hidden)  |  -Install / -Uninstall (Startup shortcut)  |  -SelfTest / -SmokeTest

param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'

# --- run under Windows PowerShell 5.1, STA (WPF + WinForms are simplest there) --
if ($PSVersionTable.PSEdition -eq 'Core' -or
    [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $fwd = @()
    foreach ($k in $PSBoundParameters.Keys) { $fwd += "-$k" }
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) + $fwd
    if ($SelfTest -or $SmokeTest) {
        & $exe @argList
        exit $LASTEXITCODE
    }
    Start-Process -FilePath $exe -ArgumentList ($argList + @('-WindowStyle', 'Hidden')) -WindowStyle Hidden
    exit 0
}

# --- paths -------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $PSCommandPath
$NotesPath = Join-Path $ScriptDir 'notes.json'
$LogPath   = Join-Path $ScriptDir 'hud.log'
$VdKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops'

function Log([string]$m) {
    try { "$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $m" | Add-Content -Path $LogPath -Encoding UTF8 } catch {}
}

# --- install / uninstall -----------------------------------------------------
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'DesktopHud.lnk'

if ($Install) {
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($StartupLnk)
    $s.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $s.WorkingDirectory = $ScriptDir
    $s.WindowStyle = 7
    $s.Description = 'Desktop HUD: per-virtual-desktop context overlay'
    $s.Save()
    Write-Host "Installed Startup shortcut: $StartupLnk"
    Write-Host "Start it now with DesktopHud.bat (or log off / on)."
    exit 0
}
if ($Uninstall) {
    if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force; Write-Host "Removed $StartupLnk" }
    else { Write-Host "No Startup shortcut found." }
    exit 0
}

# --- assemblies + native helpers ---------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

if (-not ('HudNative.Native' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace HudNative
{
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b")]
    public interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out int onCurrentDesktop);
        [PreserveSig] int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        [PreserveSig] int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
    public class CVirtualDesktopManager { }

    public static class Desktop
    {
        static IVirtualDesktopManager mgr = (IVirtualDesktopManager)new CVirtualDesktopManager();
        public static Guid WindowDesktop(IntPtr hwnd)
        {
            Guid g;
            mgr.GetWindowDesktopId(hwnd, out g);
            return g;
        }
    }

    public static class Native
    {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);

        // WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: no Alt-Tab entry,
        // never steals keyboard focus, visible on every virtual desktop.
        // clickThrough additionally sets WS_EX_TRANSPARENT so the mouse passes through.
        public static void SetOverlayStyles(IntPtr h, bool clickThrough)
        {
            long ex = (long)GetWindowLongPtr(h, -20);
            ex |= 0x80000L | 0x80L | 0x8000000L;
            if (clickThrough) ex |= 0x20L;
            SetWindowLongPtr(h, -20, (IntPtr)ex);
        }

        // NOACTIVATE must be lifted while inline editing so text boxes can take keyboard input
        public static void SetNoActivate(IntPtr h, bool on)
        {
            long ex = (long)GetWindowLongPtr(h, -20);
            if (on) ex |= 0x8000000L; else ex &= ~0x8000000L;
            SetWindowLongPtr(h, -20, (IntPtr)ex);
        }
    }

    public class HotkeyWindow : NativeWindow, IDisposable
    {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        public event Action<int> Pressed;
        public HotkeyWindow() { CreateHandle(new CreateParams()); }
        public bool Register(int id, uint mods, uint vk) { return RegisterHotKey(Handle, id, mods | 0x4000, vk); }
        public void Unregister(int id) { UnregisterHotKey(Handle, id); }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312) { var h = Pressed; if (h != null) h(m.WParam.ToInt32()); }
            base.WndProc(ref m);
        }
        public void Dispose() { DestroyHandle(); }
    }
}
'@
}

# --- virtual desktop primitives ----------------------------------------------
function Get-DesktopGuids {
    $p = Get-ItemProperty -Path $VdKey -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.VirtualDesktopIDs) { return @() }
    $raw = [byte[]]$p.VirtualDesktopIDs
    $out = @()
    for ($i = 0; $i + 16 -le $raw.Length; $i += 16) {
        $out += [guid]::new([byte[]]$raw[$i..($i + 15)])
    }
    return $out
}

function Get-CurrentDesktopGuid {
    $p = Get-ItemProperty -Path $VdKey -ErrorAction SilentlyContinue
    if ($p -and $p.CurrentVirtualDesktop) { return [guid]::new([byte[]]$p.CurrentVirtualDesktop) }
    # fallback: desktop of the foreground window (documented COM)
    try {
        $fg = [HudNative.Native]::GetForegroundWindow()
        if ($fg -ne [IntPtr]::Zero) { return [HudNative.Desktop]::WindowDesktop($fg) }
    } catch {}
    return [guid]::Empty
}

function Get-DesktopName([guid]$g) {
    $key = Join-Path $VdKey ("Desktops\{$($g.ToString().ToUpper())}")
    $n = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).Name
    if ($n) { return $n }
    $guids = Get-DesktopGuids
    $idx = [array]::IndexOf($guids, $g)
    if ($idx -ge 0) { return "Desktop $($idx + 1)" }
    return 'Desktop'
}

# --- state -------------------------------------------------------------------
$script:State = @{ settings = @{ pill = $false; hudOpacity = 0.95; hudX = $null; hudY = $null }; desktops = @{} }

function Load-State {
    if (-not (Test-Path $NotesPath)) { return }
    try {
        $j = Get-Content -Path $NotesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.settings) {
            if ($null -ne $j.settings.pill) { $script:State.settings.pill = [bool]$j.settings.pill }
            if ($j.settings.hudOpacity) { $script:State.settings.hudOpacity = [double]$j.settings.hudOpacity }
            if ($null -ne $j.settings.hudX -and $null -ne $j.settings.hudY) {
                $script:State.settings.hudX = [double]$j.settings.hudX
                $script:State.settings.hudY = [double]$j.settings.hudY
            }
        }
        if ($j.desktops) {
            foreach ($prop in $j.desktops.PSObject.Properties) {
                $secs = @()
                if ($prop.Value.sections) {
                    foreach ($s in @($prop.Value.sections)) {
                        $secs += @{
                            title = [string]$s.title
                            tasks = @(@($s.tasks) | ForEach-Object { [string]$_ })
                        }
                    }
                } elseif ($prop.Value.tasks) {
                    # migrate the old single-list format into one untitled section
                    $secs = @(@{ title = ''; tasks = @(@($prop.Value.tasks) | ForEach-Object { [string]$_ }) })
                }
                if (-not $secs) { $secs = @(@{ title = ''; tasks = @() }) }
                $script:State.desktops[$prop.Name] = @{
                    theme    = [string]$prop.Value.theme
                    sections = $secs
                    updated  = [string]$prop.Value.updated
                }
            }
        }
    } catch { Log "state load failed: $_" }
}

function Save-State {
    try {
        $script:State | ConvertTo-Json -Depth 10 | Set-Content -Path $NotesPath -Encoding UTF8
    } catch { Log "state save failed: $_" }
}

function Get-Note([guid]$g) {
    $k = $g.ToString()
    if ($script:State.desktops.ContainsKey($k)) { return $script:State.desktops[$k] }
    return @{ theme = ''; sections = @(@{ title = ''; tasks = @() }); updated = '' }
}

# --- self test ---------------------------------------------------------------
if ($SelfTest) {
    Write-Host "PS edition/apartment : $($PSVersionTable.PSEdition) / $([System.Threading.Thread]::CurrentThread.GetApartmentState())"
    Write-Host "Native types         : $([bool]('HudNative.Native' -as [type]))"
    $guids = Get-DesktopGuids
    Write-Host "Desktops found       : $($guids.Count)"
    $cur = Get-CurrentDesktopGuid
    Write-Host "Current desktop      : $cur  ($(Get-DesktopName $cur))"
    foreach ($g in $guids) { Write-Host "  - $(Get-DesktopName $g)  $g" }
    $hk = New-Object HudNative.HotkeyWindow
    $ok = $hk.Register(99, 0xC, 0x4E)   # Win+Shift+N probe
    if ($ok) { $hk.Unregister(99) }
    $hk.Dispose()
    Write-Host "Hotkey registration  : $ok"
    Load-State
    Write-Host "Notes loaded         : $($script:State.desktops.Count) desktop note(s)"
    Write-Host "SELFTEST OK"
    exit 0
}

# --- single instance ---------------------------------------------------------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\DesktopHudSingleton')
if (-not $script:Mutex.WaitOne(0)) {
    Log 'already running, exiting'
    Write-Host 'Desktop HUD is already running.'
    exit 0
}

Log '--- starting ---'
Load-State

# --- WPF windows -------------------------------------------------------------
$xamlNs = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

$hudXaml = @"
<Window $xamlNs
    WindowStyle="None" AllowsTransparency="True" Background="Transparent"
    Topmost="True" ShowInTaskbar="False" ShowActivated="False"
    SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#F5F3EF"/>
    <SolidColorBrush x:Key="InkMuted" Color="#9A98A4"/>
    <SolidColorBrush x:Key="PanelBg" Color="#F21B1B26"/>
    <SolidColorBrush x:Key="FieldBg" Color="#2A2A38"/>

    <Style x:Key="GlyphBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource InkMuted}"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="Transparent" CornerRadius="13">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#22FFFFFF"/>
                <Setter Property="Foreground" Value="{StaticResource Ink}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#33FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SoftBtn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="#1FFFFFFF" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#33FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#44FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="HudCheck" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="rowBg" Background="Transparent" CornerRadius="7" Padding="6,5">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Border x:Name="box" Grid.Column="0" Width="17" Height="17" CornerRadius="5"
                        BorderThickness="1.5" BorderBrush="{TemplateBinding BorderBrush}"
                        Background="Transparent" VerticalAlignment="Top" Margin="0,1,0,0">
                  <TextBlock x:Name="tick" Text="&#x2713;" FontSize="11" FontWeight="Bold"
                             Foreground="#1B1B26" HorizontalAlignment="Center" VerticalAlignment="Center"
                             Visibility="Collapsed" Margin="0,-1,0,0"/>
                </Border>
                <ContentPresenter Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="rowBg" Property="Background" Value="#14FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background"
                        Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="HudField" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource FieldBg}"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8"
                    BorderBrush="#00000000" BorderThickness="1">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#5BA8E0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="HudSlider" TargetType="Slider">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Slider">
            <Grid VerticalAlignment="Center" Height="18">
              <Border Height="3" CornerRadius="1.5" Background="#33FFFFFF" VerticalAlignment="Center"/>
              <Track x:Name="PART_Track">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.DecreaseLarge}">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Height="3" CornerRadius="1.5" Background="#BFFFFFFF"
                                VerticalAlignment="Center"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static Slider.IncreaseLarge}">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton">
                        <Border Background="Transparent" Height="18"/>
                      </ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Width="12" Height="12">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Ellipse Fill="{StaticResource Ink}" Stroke="#66000000" StrokeThickness="1"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Border x:Name="HudRoot" CornerRadius="18" Background="{StaticResource PanelBg}"
            BorderBrush="#26FFFFFF" BorderThickness="1" MaxWidth="560" MinWidth="340">
      <Border.Effect>
        <DropShadowEffect BlurRadius="26" ShadowDepth="6" Direction="270" Opacity="0.45" Color="#000000"/>
      </Border.Effect>
      <Border.RenderTransform>
        <TranslateTransform x:Name="HudSlide" Y="0"/>
      </Border.RenderTransform>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="HudAccentBar" Grid.Column="0" Width="4" Background="#5BA8E0"
                CornerRadius="2" Margin="10,16,0,16"/>
        <StackPanel Grid.Column="1" Margin="14,14,16,16">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="HudDesktop" FontFamily="Segoe UI Variable Display, Segoe UI"
                         FontSize="20" FontWeight="SemiBold" Foreground="{StaticResource Ink}"/>
              <TextBlock x:Name="HudProgress" FontFamily="Segoe UI Variable Text, Segoe UI"
                         FontSize="12" Foreground="{StaticResource InkMuted}"
                         Margin="10,2,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel x:Name="HudCtrls" Grid.Column="1" Orientation="Horizontal"
                        Opacity="0.25" VerticalAlignment="Center" Margin="12,0,0,0">
              <Slider x:Name="HudOpacity" Style="{StaticResource HudSlider}" Width="64"
                      Minimum="0.3" Maximum="1.0" Margin="0,0,8,0" ToolTip="Overlay opacity"/>
              <Button x:Name="HudEdit" Style="{StaticResource GlyphBtn}" Content="&#x270E;"
                      FontSize="13" ToolTip="Edit right here"/>
              <Button x:Name="HudClose" Style="{StaticResource GlyphBtn}" Content="&#x2715;"
                      ToolTip="Hide until next desktop switch"/>
            </StackPanel>
          </Grid>
          <TextBlock x:Name="HudTheme" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14"
                     Foreground="#5BA8E0" Margin="0,4,0,0" TextWrapping="Wrap"/>
          <TextBox x:Name="HudThemeBox" Style="{StaticResource HudField}" FontSize="14"
                   Visibility="Collapsed" Margin="0,8,0,0"/>
          <Grid x:Name="HudBarGrid" Margin="0,10,0,0" Height="3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition x:Name="HudBarDone" Width="0*"/>
              <ColumnDefinition x:Name="HudBarLeft" Width="1*"/>
            </Grid.ColumnDefinitions>
            <Border Grid.ColumnSpan="2" CornerRadius="1.5" Background="#1EFFFFFF"/>
            <Border x:Name="HudBarFill" Grid.Column="0" CornerRadius="1.5" Background="#5BA8E0"/>
          </Grid>
          <ScrollViewer MaxHeight="440" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="HudTasks" Margin="0,8,0,0"/>
          </ScrollViewer>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$pillXaml = @"
<Window $xamlNs
    WindowStyle="None" AllowsTransparency="True" Background="Transparent"
    Topmost="True" ShowInTaskbar="False" ShowActivated="False"
    SizeToContent="WidthAndHeight" ResizeMode="NoResize" Opacity="0.45">
  <Border x:Name="PillBorder" CornerRadius="11" Background="#CC1B1B26" Padding="14,5"
          BorderBrush="#335BA8E0" BorderThickness="1">
    <TextBlock x:Name="PillText" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12" Foreground="#F5F3EF"/>
  </Border>
</Window>
"@

$script:HudWin = [System.Windows.Markup.XamlReader]::Parse($hudXaml)
$script:HudDesktop = $HudWin.FindName('HudDesktop')
$script:HudTheme = $HudWin.FindName('HudTheme')
$script:HudTasks = $HudWin.FindName('HudTasks')
$script:HudProgress = $HudWin.FindName('HudProgress')
$script:HudBarGrid = $HudWin.FindName('HudBarGrid')
$script:HudBarDone = $HudWin.FindName('HudBarDone')
$script:HudBarLeft = $HudWin.FindName('HudBarLeft')
$script:HudCtrls = $HudWin.FindName('HudCtrls')
$script:HudSlide = $HudWin.FindName('HudSlide')
$HudWin.Opacity = 0
# one shared mutable accent brush; mutating its Color recolors every element that uses it
$script:AccentBrushObj = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromRgb(0x5B, 0xA8, 0xE0))
$HudWin.FindName('HudAccentBar').Background = $script:AccentBrushObj
$HudWin.FindName('HudBarFill').Background = $script:AccentBrushObj
$script:HudTheme.Foreground = $script:AccentBrushObj

$script:PillWin = [System.Windows.Markup.XamlReader]::Parse($pillXaml)
$script:PillText = $PillWin.FindName('PillText')
$script:PillBorder = $PillWin.FindName('PillBorder')

# HUD is interactive (tick tasks, drag, slider); pill stays click-through
$hudH = (New-Object System.Windows.Interop.WindowInteropHelper($HudWin)).EnsureHandle()
[HudNative.Native]::SetOverlayStyles($hudH, $false)
$script:HudHandle = $hudH
$script:HudEditMode = $false
$script:HudTitleBoxes = @()
$script:HudAddBoxes = @()
$pillH = (New-Object System.Windows.Interop.WindowInteropHelper($PillWin)).EnsureHandle()
[HudNative.Native]::SetOverlayStyles($pillH, $true)

$script:HudOpacitySlider = $HudWin.FindName('HudOpacity')
$HudOpacitySlider.Value = $State.settings.hudOpacity
$HudOpacitySlider.add_ValueChanged({
    param($s, $e)
    $script:State.settings.hudOpacity = [math]::Round($s.Value, 2)
    $script:HudWin.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
    $script:HudWin.Opacity = $s.Value
})
$HudOpacitySlider.add_LostMouseCapture({ Save-State })
$HudWin.FindName('HudClose').add_Click({
    if ($script:HudEditMode) { Toggle-HudEdit }
    $script:HoldTimer.Stop()
    $script:HudWin.Hide()
})
$script:HudEditBtn = $HudWin.FindName('HudEdit')
$script:HudThemeBox = $HudWin.FindName('HudThemeBox')
$script:HudEditBtn.add_Click({ Toggle-HudEdit })
$HudWin.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape' -and $script:HudEditMode) { Toggle-HudEdit } })
# drag anywhere on the panel background; controls handle their own clicks first
$HudWin.add_MouseLeftButtonDown({
    try { $script:HudWin.DragMove() } catch {}
    $script:State.settings.hudX = $script:HudWin.Left
    $script:State.settings.hudY = $script:HudWin.Top
    Save-State
})
# hovering reveals the header controls and pauses any pending auto-fade
$HudWin.add_MouseEnter({
    $script:HoldTimer.Stop()
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(150))))
    $script:HudCtrls.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
})
$HudWin.add_MouseLeave({
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.25, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))))
    $script:HudCtrls.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
    if (-not $script:HudEditMode -and $script:HudWin.IsVisible -and
        (Get-PendingCount (Get-Note $script:CurrentGuid)) -eq 0) {
        $script:HoldTimer.Stop()
        $script:HoldTimer.Start()
    }
})

# --- HUD show / hide ---------------------------------------------------------
$script:CurrentGuid = [guid]::Empty

$script:HoldTimer = New-Object System.Windows.Threading.DispatcherTimer
$HoldTimer.Interval = [TimeSpan]::FromMilliseconds(3500)
$HoldTimer.add_Tick({
    $script:HoldTimer.Stop()
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(600))))
    $a.add_Completed({ $script:HudWin.Hide() })
    $script:HudWin.BeginAnimation([System.Windows.Window]::OpacityProperty, $a)
})

function New-Brush([byte]$r, [byte]$g, [byte]$b) {
    New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromRgb($r, $g, $b))
}

# deterministic accent color per desktop GUID (HSL with fixed saturation/lightness)
function Get-AccentColor([guid]$g) {
    $bytes = $g.ToByteArray()
    $h = ((($bytes[3] * 256 + $bytes[5]) % 360)) / 360.0
    $s = 0.5
    $l = 0.66
    $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
    $p = 2 * $l - $q
    $h2r = {
        param($p, $q, $t)
        if ($t -lt 0) { $t += 1 }
        if ($t -gt 1) { $t -= 1 }
        if ($t -lt (1 / 6)) { return $p + ($q - $p) * 6 * $t }
        if ($t -lt 0.5) { return $q }
        if ($t -lt (2 / 3)) { return $p + ($q - $p) * ((2 / 3) - $t) * 6 }
        return $p
    }
    $r = & $h2r $p $q ($h + (1 / 3))
    $gr = & $h2r $p $q $h
    $bl = & $h2r $p $q ($h - (1 / 3))
    return [System.Windows.Media.Color]::FromRgb(
        [byte][math]::Round($r * 255), [byte][math]::Round($gr * 255), [byte][math]::Round($bl * 255))
}

function Set-HudAccent {
    $script:AccentBrushObj.Color = Get-AccentColor $script:CurrentGuid
}

function Update-HudProgress {
    $note = Get-Note $script:CurrentGuid
    $total = 0
    $done = 0
    foreach ($s in @($note.sections)) {
        foreach ($t in @($s.tasks)) {
            if (-not $t) { continue }
            $total++
            if (([string]$t).TrimStart().StartsWith('x ')) { $done++ }
        }
    }
    if ($total -eq 0) {
        $script:HudProgress.Text = ''
        $script:HudBarGrid.Visibility = 'Collapsed'
    } else {
        $script:HudProgress.Text = "$done / $total"
        $script:HudBarGrid.Visibility = 'Visible'
        $script:HudBarDone.Width = New-Object System.Windows.GridLength([double]$done, [System.Windows.GridUnitType]::Star)
        $script:HudBarLeft.Width = New-Object System.Windows.GridLength([double]($total - $done), [System.Windows.GridUnitType]::Star)
    }
}

function Get-PendingCount($note) {
    $n = 0
    foreach ($s in @($note.sections)) {
        $n += @(@($s.tasks) | Where-Object { $_ -and -not ([string]$_).TrimStart().StartsWith('x ') }).Count
    }
    return $n
}

function Set-HudNote($note) {
    $script:State.desktops[$script:CurrentGuid.ToString()] = @{
        theme    = [string]$note.theme
        sections = @($note.sections)
        updated  = (Get-Date).ToString('s')
    }
    Save-State
}

# saves what is currently typed in the edit-mode boxes (theme + section titles)
function Persist-HudEdits {
    if (-not $script:HudEditMode) { return }
    $note = Get-Note $script:CurrentGuid
    $note.theme = $script:HudThemeBox.Text.Trim()
    for ($i = 0; $i -lt $script:HudTitleBoxes.Count -and $i -lt @($note.sections).Count; $i++) {
        $note.sections[$i].title = $script:HudTitleBoxes[$i].Text.Trim()
    }
    Set-HudNote $note
}

function Complete-HudTask($cb) {
    $tag = $cb.Tag
    $note = Get-Note $script:CurrentGuid
    if ($tag.sec -ge @($note.sections).Count) { return }
    $tasks = @($note.sections[$tag.sec].tasks)
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $trim = ([string]$tasks[$i]).TrimStart()
        if ($cb.IsChecked -and $trim -eq $tag.text) { $tasks[$i] = "x $($tag.text)"; break }
        if (-not $cb.IsChecked -and $trim -eq "x $($tag.text)") { $tasks[$i] = $tag.text; break }
    }
    $note.sections[$tag.sec].tasks = $tasks
    Set-HudNote $note
    Set-DoneStyle $cb
    Update-HudProgress
    # when the last pending task is ticked, let the panel fade out
    $script:HoldTimer.Stop()
    if ((Get-PendingCount $note) -eq 0 -and -not $script:HudEditMode) { $script:HoldTimer.Start() }
}

function Remove-HudTask([int]$sec, [string]$txt) {
    $note = Get-Note $script:CurrentGuid
    if ($sec -ge @($note.sections).Count) { return }
    $tasks = [System.Collections.ArrayList]@($note.sections[$sec].tasks)
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        if (([string]$tasks[$i]).TrimStart() -eq $txt) { $tasks.RemoveAt($i); break }
    }
    $note.sections[$sec].tasks = @($tasks)
    Set-HudNote $note
    [void](Render-HudContent)
}

function Add-HudTask([int]$sec) {
    if ($sec -ge $script:HudAddBoxes.Count) { return }
    $t = $script:HudAddBoxes[$sec].Text.Trim()
    if (-not $t) { return }
    Persist-HudEdits
    $note = Get-Note $script:CurrentGuid
    $note.sections[$sec].tasks = @(@($note.sections[$sec].tasks) + $t)
    Set-HudNote $note
    [void](Render-HudContent)
    if ($sec -lt $script:HudAddBoxes.Count) { [void]$script:HudAddBoxes[$sec].Focus() }
}

function Add-HudSection {
    Persist-HudEdits
    $note = Get-Note $script:CurrentGuid
    $secs = @($note.sections)
    $secs += @{ title = "Section $($secs.Count + 1)"; tasks = @() }
    $note.sections = $secs
    Set-HudNote $note
    [void](Render-HudContent)
    if ($script:HudTitleBoxes.Count) {
        $box = $script:HudTitleBoxes[$script:HudTitleBoxes.Count - 1]
        [void]$box.Focus()
        $box.SelectAll()
    }
}

function Remove-HudSection([int]$sec) {
    Persist-HudEdits
    $note = Get-Note $script:CurrentGuid
    $secs = [System.Collections.ArrayList]@($note.sections)
    if ($sec -lt $secs.Count) { $secs.RemoveAt($sec) }
    if ($secs.Count -eq 0) { [void]$secs.Add(@{ title = ''; tasks = @() }) }
    $note.sections = @($secs)
    Set-HudNote $note
    [void](Render-HudContent)
}

# rebuilds the HUD content (sections, tasks, edit-mode widgets); returns the pending count
function Render-HudContent {
    $note = Get-Note $script:CurrentGuid
    $script:HudTasks.Children.Clear()
    $script:HudTitleBoxes = @()
    $script:HudAddBoxes = @()
    $secs = @($note.sections)
    $glyphStyle = $script:HudWin.Resources['GlyphBtn']
    $softStyle = $script:HudWin.Resources['SoftBtn']
    $fieldStyle = $script:HudWin.Resources['HudField']
    $checkStyle = $script:HudWin.Resources['HudCheck']
    $accentBrush = $script:AccentBrushObj

    for ($si = 0; $si -lt $secs.Count; $si++) {
        $sec = $secs[$si]
        $topGap = if ($si -eq 0) { 0.0 } else { 14.0 }

        if ($script:HudEditMode) {
            # editable section title with a remove-section button
            $trow = New-Object System.Windows.Controls.DockPanel
            $trow.Margin = New-Object System.Windows.Thickness(0, $topGap, 0, 0)
            $rem = New-Object System.Windows.Controls.Button
            $rem.Style = $glyphStyle
            $rem.Content = [string][char]0x2715
            $rem.FontSize = 10
            $rem.Width = 22
            $rem.Height = 22
            $rem.ToolTip = 'Remove this section (and its tasks)'
            $rem.Tag = $si
            $rem.add_Click({ param($s, $e) Remove-HudSection ([int]$s.Tag) })
            [System.Windows.Controls.DockPanel]::SetDock($rem, 'Right')
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Style = $fieldStyle
            $tb.Text = [string]$sec.title
            $tb.FontWeight = 'SemiBold'
            $tb.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
            $tb.ToolTip = 'Section title'
            $script:HudTitleBoxes += $tb
            [void]$trow.Children.Add($rem)
            [void]$trow.Children.Add($tb)
            [void]$script:HudTasks.Children.Add($trow)
        } elseif (([string]$sec.title).Trim() -or $secs.Count -gt 1) {
            $tl = New-Object System.Windows.Controls.TextBlock
            $tl.Text = if (([string]$sec.title).Trim()) { ([string]$sec.title).ToUpper() } else { "SECTION $($si + 1)" }
            $tl.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
            $tl.FontSize = 11
            $tl.FontWeight = 'Bold'
            $tl.Opacity = 0.9
            $tl.Foreground = $accentBrush
            $tl.Margin = New-Object System.Windows.Thickness(6, $topGap, 0, 2)
            [void]$script:HudTasks.Children.Add($tl)
        }

        $pending = @(@($sec.tasks) | Where-Object { $_ -and -not ([string]$_).TrimStart().StartsWith('x ') })
        foreach ($t in $pending) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = New-Object System.Windows.Thickness(0, 1, 0, 0)

            $del = New-Object System.Windows.Controls.Button
            $del.Style = $glyphStyle
            $del.Content = [string][char]0x2715
            $del.FontSize = 10
            $del.Width = 22
            $del.Height = 22
            $del.VerticalAlignment = 'Center'
            $del.ToolTip = 'Delete task'
            $del.Tag = @{ sec = $si; text = ([string]$t).TrimStart() }
            $del.Visibility = if ($script:HudEditMode) { 'Visible' } else { 'Collapsed' }
            $del.add_Click({ param($s, $e) Remove-HudTask ([int]$s.Tag.sec) ([string]$s.Tag.text) })
            [System.Windows.Controls.DockPanel]::SetDock($del, 'Right')

            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Style = $checkStyle
            $cb.BorderBrush = $accentBrush
            $cb.Tag = @{ sec = $si; text = ([string]$t).TrimStart() }
            $tbx = New-Object System.Windows.Controls.TextBlock
            $tbx.Text = ([string]$t).TrimStart()
            $tbx.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
            $tbx.FontSize = 14
            $tbx.TextWrapping = 'Wrap'
            $cb.Content = $tbx
            Set-DoneStyle $cb
            $cb.add_Click({ param($s, $e) Complete-HudTask $s })

            [void]$row.Children.Add($del)
            [void]$row.Children.Add($cb)
            [void]$script:HudTasks.Children.Add($row)
        }

        if ($script:HudEditMode) {
            # per-section add-task row
            $arow = New-Object System.Windows.Controls.DockPanel
            $arow.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $abtn = New-Object System.Windows.Controls.Button
            $abtn.Style = $softStyle
            $abtn.Content = 'Add'
            $abtn.Tag = $si
            $abtn.add_Click({ param($s, $e) Add-HudTask ([int]$s.Tag) })
            [System.Windows.Controls.DockPanel]::SetDock($abtn, 'Right')
            $abox = New-Object System.Windows.Controls.TextBox
            $abox.Style = $fieldStyle
            $abox.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
            $abox.ToolTip = 'New task, Enter to add'
            $abox.Tag = $si
            $abox.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Add-HudTask ([int]$s.Tag) } })
            $script:HudAddBoxes += $abox
            [void]$arow.Children.Add($abtn)
            [void]$arow.Children.Add($abox)
            [void]$script:HudTasks.Children.Add($arow)
        }
    }

    if ($script:HudEditMode) {
        $sbtn = New-Object System.Windows.Controls.Button
        $sbtn.Style = $softStyle
        $sbtn.Content = '+ section'
        $sbtn.HorizontalAlignment = 'Left'
        $sbtn.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $sbtn.add_Click({ Add-HudSection })
        [void]$script:HudTasks.Children.Add($sbtn)
    }

    Update-HudProgress
    return (Get-PendingCount $note)
}

function Toggle-HudEdit {
    if (-not $script:HudEditMode) {
        $script:HudEditMode = $true
        $script:HoldTimer.Stop()
        [HudNative.Native]::SetNoActivate($script:HudHandle, $false)
        $note = Get-Note $script:CurrentGuid
        $script:HudThemeBox.Text = $note.theme
        $script:HudTheme.Visibility = 'Collapsed'
        $script:HudThemeBox.Visibility = 'Visible'
        $script:HudEditBtn.Content = [string][char]0x2713
        $script:HudEditBtn.ToolTip = 'Done editing'
        [void](Render-HudContent)
        $script:HudWin.Activate()
        if ($script:HudAddBoxes.Count) { [void]$script:HudAddBoxes[0].Focus() }
    } else {
        Persist-HudEdits
        $script:HudEditMode = $false
        $note = Get-Note $script:CurrentGuid
        if ($note.theme) { $script:HudTheme.Text = $note.theme }
        else { $script:HudTheme.Text = 'No note yet. Click the pencil to set the theme.' }
        $script:HudTheme.Visibility = 'Visible'
        $script:HudThemeBox.Visibility = 'Collapsed'
        $script:HudEditBtn.Content = [string][char]0x270E
        $script:HudEditBtn.ToolTip = 'Edit right here'
        [HudNative.Native]::SetNoActivate($script:HudHandle, $true)
        Update-Pill
        $pendingLeft = Render-HudContent
        $script:HoldTimer.Stop()
        if ($pendingLeft -eq 0) { $script:HoldTimer.Start() }
    }
}

# hotkey / tray entry point: bring up the HUD already in edit mode
function Open-HudEditor {
    Show-Hud
    if (-not $script:HudEditMode) { Toggle-HudEdit }
}

function Show-Hud {
    if ($script:CurrentGuid -eq [guid]::Empty) { return }
    if ($script:HudEditMode) { Toggle-HudEdit }
    Set-HudAccent
    $note = Get-Note $script:CurrentGuid
    $script:HudDesktop.Text = Get-DesktopName $script:CurrentGuid
    if ($note.theme) { $script:HudTheme.Text = $note.theme }
    else { $script:HudTheme.Text = 'No note yet. Click the pencil to set the theme.' }
    $pendingCount = Render-HudContent
    $script:HoldTimer.Stop()
    $script:HudWin.Show()
    $script:HudWin.UpdateLayout()
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($null -ne $script:State.settings.hudX -and $null -ne $script:State.settings.hudY) {
        # restore the dragged position, clamped to the full multi-monitor virtual screen
        $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vt = [System.Windows.SystemParameters]::VirtualScreenTop
        $vr = $vl + [System.Windows.SystemParameters]::VirtualScreenWidth
        $vb = $vt + [System.Windows.SystemParameters]::VirtualScreenHeight
        $script:HudWin.Left = [math]::Min([math]::Max([double]$script:State.settings.hudX, $vl), $vr - $script:HudWin.ActualWidth)
        $script:HudWin.Top = [math]::Min([math]::Max([double]$script:State.settings.hudY, $vt), $vb - $script:HudWin.ActualHeight)
    } else {
        $script:HudWin.Left = $wa.Left + ($wa.Width - $script:HudWin.ActualWidth) / 2
        $script:HudWin.Top = $wa.Top + $wa.Height * 0.2
    }
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation([double]$script:State.settings.hudOpacity, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(200))))
    $script:HudWin.BeginAnimation([System.Windows.Window]::OpacityProperty, $a)
    # gentle rise-in
    $script:HudSlide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $script:HudSlide.Y = 12
    $sa = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, (New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(280))))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'
    $sa.EasingFunction = $ease
    $script:HudSlide.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $sa)
    # stays visible while tasks are pending; fades only when there is nothing to do
    if ($pendingCount -eq 0) { $script:HoldTimer.Start() }
}

function Update-Pill {
    if (-not $script:State.settings.pill -or $script:CurrentGuid -eq [guid]::Empty) {
        $script:PillWin.Hide()
        return
    }
    $note = Get-Note $script:CurrentGuid
    $txt = Get-DesktopName $script:CurrentGuid
    if ($note.theme) { $txt = "$txt   $([char]0x2022)   $($note.theme)" }
    $script:PillText.Text = $txt
    $script:PillBorder.BorderBrush = New-Object System.Windows.Media.SolidColorBrush((Get-AccentColor $script:CurrentGuid))
    $script:PillWin.Show()
    $script:PillWin.UpdateLayout()
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:PillWin.Left = $wa.Left + ($wa.Width - $script:PillWin.ActualWidth) / 2
    $script:PillWin.Top = $wa.Top + 6
}

# --- task styling ------------------------------------------------------------
function Set-DoneStyle($cb) {
    $tbx = $cb.Content
    if ($cb.IsChecked) {
        $tbx.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        $tbx.Foreground = New-Brush 0x9A 0x98 0xA4
        $tbx.Opacity = 0.75
    } else {
        $tbx.TextDecorations = $null
        $tbx.Foreground = New-Brush 0xF5 0xF3 0xEF
        $tbx.Opacity = 1.0
    }
}

# --- hotkeys -----------------------------------------------------------------
# MOD_SHIFT (0x4) | MOD_WIN (0x8) = 0xC
$script:HotWin = New-Object HudNative.HotkeyWindow
$script:HotWin.add_Pressed({
    param($id)
    try {
        switch ($id) {
            1 { Open-HudEditor }
            2 { Show-Hud }
            3 {
                $script:State.settings.pill = -not $script:State.settings.pill
                Save-State
                Update-Pill
            }
        }
    } catch { Log "hotkey handler error: $_" }
})
if (-not $HotWin.Register(1, 0xC, 0x4E)) { Log 'WARN: Win+Shift+N registration failed' }
if (-not $HotWin.Register(2, 0xC, 0x48)) { Log 'WARN: Win+Shift+H registration failed' }
if (-not $HotWin.Register(3, 0xC, 0x42)) { Log 'WARN: Win+Shift+B registration failed' }

# --- tray icon ---------------------------------------------------------------
$bmp = New-Object System.Drawing.Bitmap 16, 16
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.SmoothingMode = 'AntiAlias'
$gfx.Clear([System.Drawing.Color]::Transparent)
$gfx.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0x24, 0x94, 0xDC))), 1, 1, 14, 14)
$gfx.FillEllipse([System.Drawing.Brushes]::White, 6, 6, 4, 4)
$gfx.Dispose()
$script:TrayIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$Tray.Icon = $script:TrayIcon
$Tray.Text = 'Desktop HUD'
$Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Edit note  (Win+Shift+N)', $null, { Open-HudEditor })
[void]$menu.Items.Add('Show HUD  (Win+Shift+H)', $null, { Show-Hud })
[void]$menu.Items.Add('Toggle pill  (Win+Shift+B)', $null, {
    $script:State.settings.pill = -not $script:State.settings.pill
    Save-State
    Update-Pill
})
[void]$menu.Items.Add('Open notes folder', $null, { Start-Process explorer.exe $ScriptDir })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Exit', $null, { $script:App.Shutdown() })
$Tray.ContextMenuStrip = $menu
$Tray.add_DoubleClick({ Open-HudEditor })

# --- desktop switch polling --------------------------------------------------
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$PollTimer.add_Tick({
    try {
        $g = Get-CurrentDesktopGuid
        if ($g -ne [guid]::Empty -and $g -ne $script:CurrentGuid) {
            # leaving a desktop while inline-editing: save against the old desktop first
            if ($script:HudEditMode) { Toggle-HudEdit }
            $script:CurrentGuid = $g
            Update-Pill
            Show-Hud
        }
    } catch { Log "poll error: $_`n$($_.InvocationInfo.PositionMessage)" }
})
$PollTimer.Start()

# --- run ---------------------------------------------------------------------
$script:App = New-Object System.Windows.Application
$App.ShutdownMode = 'OnExplicitShutdown'

if ($SmokeTest) {
    # step 1: open editor (exercises checklist build), step 2: close it (exercises save), step 3: exit
    $script:SmokeStep = 0
    $smoke = New-Object System.Windows.Threading.DispatcherTimer
    $smoke.Interval = [TimeSpan]::FromSeconds(2)
    $smoke.add_Tick({
        $script:SmokeStep++
        try {
            switch ($script:SmokeStep) {
                1 { Open-HudEditor }
                2 { if ($script:HudEditMode) { Toggle-HudEdit } }
                default { $script:App.Shutdown() }
            }
        } catch {
            Log "SMOKE FAIL: $_"
            $script:App.Shutdown()
        }
    })
    $smoke.Start()
}

Log 'running'
try {
    [void]$App.Run()
} finally {
    $PollTimer.Stop()
    $HoldTimer.Stop()
    foreach ($id in 1..3) { try { $HotWin.Unregister($id) } catch {} }
    try { $HotWin.Dispose() } catch {}
    $Tray.Visible = $false
    $Tray.Dispose()
    try { $script:Mutex.ReleaseMutex() } catch {}
    Log 'stopped'
}
if ($SmokeTest) { Write-Host 'SMOKE OK' }
