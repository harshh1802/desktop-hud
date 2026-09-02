# Desktop HUD: per-virtual-desktop context overlay.
# Shows a transient HUD (desktop name + theme + tasks) whenever you switch virtual desktops,
# plus an optional tiny always-visible "anchor pill". Notes are keyed by desktop GUID.
# Built on stable surfaces only: VirtualDesktops registry + documented IVirtualDesktopManager COM.
#
# Hotkeys:  Win+Shift+N quick-add task   Win+Shift+H show panel   Win+Shift+B toggle pill
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
if ($SmokeTest) {
    # never let a test touch real notes
    $NotesPath = Join-Path $env:TEMP 'desktophud_smoke_notes.json'
    if (Test-Path $NotesPath) { Remove-Item $NotesPath -Force }
}
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
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);

        // WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: no Alt-Tab entry,
        // never steals keyboard focus, visible on every virtual desktop.
        // clickThrough additionally sets WS_EX_TRANSPARENT so the mouse passes through.
        public static void SetOverlayStyles(IntPtr h, bool clickThrough, bool noActivate)
        {
            long ex = (long)GetWindowLongPtr(h, -20);
            ex |= 0x80000L | 0x80L;
            if (clickThrough) ex |= 0x20L;
            if (noActivate) ex |= 0x8000000L; else ex &= ~0x8000000L;
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
$script:State = @{ settings = @{ pill = $false; showDone = $false; hudOpacity = 0.95; hudX = $null; hudY = $null }; desktops = @{} }

function Load-State {
    if (-not (Test-Path $NotesPath)) { return }
    try {
        $j = Get-Content -Path $NotesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.settings) {
            if ($null -ne $j.settings.pill) { $script:State.settings.pill = [bool]$j.settings.pill }
            if ($null -ne $j.settings.showDone) { $script:State.settings.showDone = [bool]$j.settings.showDone }
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
$mutexName = if ($SmokeTest) { 'Local\DesktopHudSmoke' } else { 'Local\DesktopHudSingleton' }
$script:Mutex = New-Object System.Threading.Mutex($false, $mutexName)
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

    <!-- always-editable text: looks like a label, becomes a field the moment you click it.
         Tag carries placeholder text, Uid carries the "section:index" address. -->
    <Style x:Key="TaskBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Ink}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="AcceptsReturn" Value="False"/>
      <Setter Property="Padding" Value="5,3"/>
      <Setter Property="SelectionOpacity" Value="0.4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Grid>
              <Border x:Name="bd" Background="Transparent" CornerRadius="6"/>
              <TextBlock x:Name="ph" Text="{TemplateBinding Tag}" Foreground="#7C7A86"
                         FontFamily="{TemplateBinding FontFamily}" FontSize="{TemplateBinding FontSize}"
                         Margin="{TemplateBinding Padding}" Visibility="Collapsed" IsHitTestVisible="False"/>
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="Text" Value="">
                <Setter TargetName="ph" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#12FFFFFF"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#24FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- the ghost "+ add task" row that sits permanently at the end of every section -->
    <Style x:Key="GhostBox" TargetType="TextBox" BasedOn="{StaticResource TaskBox}">
      <Setter Property="FontSize" Value="13"/>
    </Style>

    <Style x:Key="TitleBox" TargetType="TextBox" BasedOn="{StaticResource TaskBox}">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>

    <Style x:Key="ThemeBox" TargetType="TextBox" BasedOn="{StaticResource TaskBox}">
      <Setter Property="FontSize" Value="14"/>
    </Style>

    <!-- checkbox with no label: the task text lives in its own editable field beside it -->
    <Style x:Key="HudBox" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border Background="Transparent" Padding="5,6,3,4">
              <Border x:Name="box" Width="17" Height="17" CornerRadius="5"
                      BorderThickness="1.5" BorderBrush="{TemplateBinding BorderBrush}"
                      Background="Transparent">
                <TextBlock x:Name="tick" Text="&#x2713;" FontSize="11" FontWeight="Bold"
                           Foreground="#1B1B26" HorizontalAlignment="Center" VerticalAlignment="Center"
                           Visibility="Collapsed" Margin="0,-1,0,0"/>
              </Border>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="box" Property="Background" Value="#22FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{Binding BorderBrush, RelativeSource={RelativeSource TemplatedParent}}"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
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
              <Button x:Name="HudEye" Style="{StaticResource GlyphBtn}" FontFamily="Segoe MDL2 Assets"
                      Content="&#xE7B3;" FontSize="13" ToolTip="Show completed tasks"/>
              <Button x:Name="HudClose" Style="{StaticResource GlyphBtn}" Content="&#x2715;"
                      ToolTip="Hide until next desktop switch"/>
            </StackPanel>
          </Grid>
          <TextBox x:Name="HudThemeBox" Style="{StaticResource ThemeBox}" Uid="theme"
                   Tag="what is this desktop for?" Margin="-5,2,0,0"/>
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

$script:PillWin = [System.Windows.Markup.XamlReader]::Parse($pillXaml)
$script:PillText = $PillWin.FindName('PillText')
$script:PillBorder = $PillWin.FindName('PillBorder')

# HUD is fully interactive: it must be able to take focus when you click into a field,
# so it does NOT carry WS_EX_NOACTIVATE. ShowActivated=False is what keeps it from
# stealing focus when it merely appears. The pill stays click-through and passive.
$hudH = (New-Object System.Windows.Interop.WindowInteropHelper($HudWin)).EnsureHandle()
[HudNative.Native]::SetOverlayStyles($hudH, $false, $false)
$script:HudHandle = $hudH
$pillH = (New-Object System.Windows.Interop.WindowInteropHelper($PillWin)).EnsureHandle()
[HudNative.Native]::SetOverlayStyles($pillH, $true, $true)

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
    $script:HoldTimer.Stop()
    $script:HudWin.Hide()
})
$script:HudThemeBox = $HudWin.FindName('HudThemeBox')
$script:HudRoot = $HudWin.FindName('HudRoot')
$script:HudEyeBtn = $HudWin.FindName('HudEye')
$script:HudThemeBox.Foreground = $script:AccentBrushObj
$script:HudThemeBox.CaretBrush = $script:AccentBrushObj
$script:HudEyeBtn.add_Click({ Toggle-ShowDone })
$script:HudThemeBox.add_LostFocus({ Commit-Theme })
$script:HudThemeBox.add_KeyDown({
    param($s, $e)
    if ($e.Key -eq 'Return') { Commit-Theme; Move-FocusToFirstAdd; $e.Handled = $true }
    elseif ($e.Key -eq 'Escape') { Blur-Hud }
})
# drag by the panel background; text fields and buttons consume their own clicks first
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
    Start-IdleFade
})

# --- HUD show / hide ---------------------------------------------------------
$script:CurrentGuid = [guid]::Empty

$script:UndoData = $null
$script:UndoTimer = New-Object System.Windows.Threading.DispatcherTimer
$UndoTimer.Interval = [TimeSpan]::FromSeconds(8)
$UndoTimer.add_Tick({
    $script:UndoTimer.Stop()
    $script:UndoData = $null
    if ($script:HudWin.IsVisible) { [void](Render-HudContent) }
})

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

# --- addressing: every editable control carries "<section>:<index|title|add>" in Uid --
function Get-Addr($ctl) {
    $parts = ([string]$ctl.Uid) -split ':'
    if ($parts.Count -lt 2) { return $null }
    return @{ sec = [int]$parts[0]; slot = $parts[1] }
}

# the panel auto-fades only when idle: nothing pending, not hovered, not being typed in
function Start-IdleFade {
    $script:HoldTimer.Stop()
    if (-not $script:HudWin.IsVisible) { return }
    if ($script:HudWin.IsMouseOver -or $script:HudWin.IsKeyboardFocusWithin) { return }
    if ((Get-PendingCount (Get-Note $script:CurrentGuid)) -ne 0) { return }
    $script:HoldTimer.Start()
}

function Blur-Hud {
    # hand keyboard focus back to whatever the user was working in
    [System.Windows.Input.Keyboard]::ClearFocus()
    try {
        $prev = $script:PrevForeground
        if ($prev -and $prev -ne [IntPtr]::Zero -and $prev -ne $script:HudHandle -and
            [HudNative.Native]::IsWindow($prev)) {
            [void][HudNative.Native]::SetForegroundWindow($prev)
        }
    } catch {}
    Start-IdleFade
}

function Complete-HudTask($cb) {
    $a = Get-Addr $cb
    if (-not $a) { return }
    $note = Get-Note $script:CurrentGuid
    if ($a.sec -ge @($note.sections).Count) { return }
    $tasks = @($note.sections[$a.sec].tasks)
    $i = [int]$a.slot
    if ($i -lt 0 -or $i -ge $tasks.Count) { return }
    $body = ([string]$tasks[$i]).TrimStart()
    if ($body.StartsWith('x ')) { $body = $body.Substring(2) }
    $tasks[$i] = if ($cb.IsChecked) { "x $body" } else { $body }
    $note.sections[$a.sec].tasks = $tasks
    Set-HudNote $note
    Update-HudProgress
    # hiding completed items changes the list, so rebuild; otherwise just restyle in place
    if (-not $script:State.settings.showDone) { [void](Render-HudContent) }
    else {
        foreach ($t in $script:HudFocusables) {
            if ([string]$t.Uid -eq [string]$cb.Uid) { Set-TaskDoneStyle $t $cb.IsChecked }
        }
    }
    Start-IdleFade
}

# commit an edited task's text (called on Enter and on focus loss); no re-render, so
# the caret stays exactly where the user put it
function Commit-TaskText($tb) {
    # a rebuild tears controls out of the tree, which fires LostFocus with a stale
    # address; ignore those or they would write over the wrong task
    if ($script:Rendering) { return }
    $a = Get-Addr $tb
    if (-not $a) { return }
    $note = Get-Note $script:CurrentGuid
    if ($a.sec -ge @($note.sections).Count) { return }
    $tasks = @($note.sections[$a.sec].tasks)
    $i = [int]$a.slot
    if ($i -lt 0 -or $i -ge $tasks.Count) { return }
    $wasDone = ([string]$tasks[$i]).TrimStart().StartsWith('x ')
    $new = $tb.Text.Trim()
    if (-not $new) {
        # emptying a task deletes it, with undo
        $raw = [string]$tasks[$i]
        $list = [System.Collections.ArrayList]$tasks
        $list.RemoveAt($i)
        $note.sections[$a.sec].tasks = @($list)
        Set-HudNote $note
        Set-HudUndo @{ type = 'task'; sec = $a.sec; idx = $i; text = $raw } 'Task deleted'
        [void](Render-HudContent)
        return
    }
    $tasks[$i] = if ($wasDone) { "x $new" } else { $new }
    $note.sections[$a.sec].tasks = $tasks
    Set-HudNote $note
}

function Commit-SectionTitle($tb) {
    if ($script:Rendering) { return }
    $a = Get-Addr $tb
    if (-not $a) { return }
    $note = Get-Note $script:CurrentGuid
    if ($a.sec -ge @($note.sections).Count) { return }
    $note.sections[$a.sec].title = $tb.Text.Trim()
    Set-HudNote $note
}

function Commit-Theme {
    $note = Get-Note $script:CurrentGuid
    $note.theme = $script:HudThemeBox.Text.Trim()
    Set-HudNote $note
    Update-Pill
}

# --- undo (single-level, for destructive actions) ----------------------------
function Set-HudUndo($data, [string]$label) {
    $data.label = $label
    $data.guid = $script:CurrentGuid
    $script:UndoData = $data
    $script:UndoTimer.Stop()
    $script:UndoTimer.Start()
}

function Invoke-HudUndo {
    $u = $script:UndoData
    $script:UndoData = $null
    $script:UndoTimer.Stop()
    if (-not $u -or $u.guid -ne $script:CurrentGuid) { [void](Render-HudContent); return }
    $note = Get-Note $script:CurrentGuid
    switch ($u.type) {
        'task' {
            if ($u.sec -lt @($note.sections).Count) {
                $tasks = [System.Collections.ArrayList]@($note.sections[$u.sec].tasks)
                $idx = [math]::Min([math]::Max($u.idx, 0), $tasks.Count)
                $tasks.Insert($idx, $u.text)
                $note.sections[$u.sec].tasks = @($tasks)
            }
        }
        'section' {
            $secs = [System.Collections.ArrayList]@($note.sections)
            if ($secs.Count -eq 1 -and -not ([string]$secs[0].title).Trim() -and @($secs[0].tasks).Count -eq 0) {
                $secs.RemoveAt(0)
            }
            $idx = [math]::Min([math]::Max($u.idx, 0), $secs.Count)
            $secs.Insert($idx, $u.data)
            $note.sections = @($secs)
        }
        'cleardone' {
            foreach ($k in $u.map.Keys) {
                if ($k -lt @($note.sections).Count) {
                    $note.sections[$k].tasks = @(@($note.sections[$k].tasks) + @($u.map[$k]))
                }
            }
        }
    }
    Set-HudNote $note
    [void](Render-HudContent)
}

function Clear-DoneTasks {
    $note = Get-Note $script:CurrentGuid
    $removed = @{}
    for ($i = 0; $i -lt @($note.sections).Count; $i++) {
        $keep = @()
        $gone = @()
        foreach ($t in @($note.sections[$i].tasks)) {
            if ($t -and ([string]$t).TrimStart().StartsWith('x ')) { $gone += $t } else { $keep += $t }
        }
        if ($gone.Count) { $removed[$i] = $gone }
        $note.sections[$i].tasks = $keep
    }
    if ($removed.Count -eq 0) { return }
    Set-HudNote $note
    Set-HudUndo @{ type = 'cleardone'; map = $removed } 'Completed tasks cleared'
    [void](Render-HudContent)
}

# --- show-completed setting --------------------------------------------------
function Update-ShowDoneUi {
    if ($script:State.settings.showDone) { $script:HudEyeBtn.Foreground = $script:AccentBrushObj }
    else { $script:HudEyeBtn.Foreground = New-Brush 0x9A 0x98 0xA4 }
    if ($script:TrayShowDone) { $script:TrayShowDone.Checked = [bool]$script:State.settings.showDone }
}

function Toggle-ShowDone {
    $script:State.settings.showDone = -not $script:State.settings.showDone
    Save-State
    Update-ShowDoneUi
    if ($script:HudWin.IsVisible) { [void](Render-HudContent) }
}

function Remove-HudTask([int]$sec, [int]$idx) {
    $note = Get-Note $script:CurrentGuid
    if ($sec -ge @($note.sections).Count) { return }
    $tasks = [System.Collections.ArrayList]@($note.sections[$sec].tasks)
    if ($idx -lt 0 -or $idx -ge $tasks.Count) { return }
    $raw = [string]$tasks[$idx]
    $tasks.RemoveAt($idx)
    $note.sections[$sec].tasks = @($tasks)
    Set-HudNote $note
    Set-HudUndo @{ type = 'task'; sec = $sec; idx = $idx; text = $raw } 'Task deleted'
    [void](Render-HudContent)
}

# focus the control whose Uid matches, once the new visual tree has been laid out
function Set-FocusByUid([string]$uid) {
    $act = [System.Action] {
        foreach ($c in $script:HudFocusables) {
            if ([string]$c.Uid -eq $script:PendingFocusUid) {
                $script:HudWin.Activate()
                [void]$c.Focus()
                [void][System.Windows.Input.Keyboard]::Focus($c)
                if ($c -is [System.Windows.Controls.TextBox]) { $c.CaretIndex = $c.Text.Length }
                break
            }
        }
    }
    $script:PendingFocusUid = $uid
    [void]$script:HudWin.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, $act)
}

# Enter on a ghost add-row: append the task, rebuild, and land the caret back in the
# (now empty) add-row so the next thought can be typed straight away
function Add-HudTask($tb) {
    $a = Get-Addr $tb
    if (-not $a) { return }
    $t = $tb.Text.Trim()
    if (-not $t) { Blur-Hud; return }
    $note = Get-Note $script:CurrentGuid
    if ($a.sec -ge @($note.sections).Count) { return }
    $note.sections[$a.sec].tasks = @(@($note.sections[$a.sec].tasks) + $t)
    Set-HudNote $note
    $tb.Text = ''
    [void](Render-HudContent)
    Set-FocusByUid "$($a.sec):add"
}

function Add-HudSection {
    $note = Get-Note $script:CurrentGuid
    $secs = @($note.sections)
    $secs += @{ title = ''; tasks = @() }
    $note.sections = $secs
    Set-HudNote $note
    [void](Render-HudContent)
    Set-FocusByUid "$($secs.Count - 1):title"
}

function Remove-HudSection([int]$sec) {
    $note = Get-Note $script:CurrentGuid
    $secs = [System.Collections.ArrayList]@($note.sections)
    if ($sec -ge $secs.Count) { return }
    $data = $secs[$sec]
    $secs.RemoveAt($sec)
    if ($secs.Count -eq 0) { [void]$secs.Add(@{ title = ''; tasks = @() }) }
    $note.sections = @($secs)
    Set-HudNote $note
    Set-HudUndo @{ type = 'section'; idx = $sec; data = $data } 'Section deleted'
    [void](Render-HudContent)
}

# one task row: [delete (edit mode)][checkbox + text]
function New-HudTaskRow([int]$si, [int]$idx, [string]$raw, [bool]$done) {
    $trimmed = $raw.TrimStart()
    $text = if ($done) { $trimmed.Substring(2) } else { $trimmed }
    $addr = "$($si):$idx"

    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = New-Object System.Windows.Thickness(0, 1, 0, 0)

    $del = New-Object System.Windows.Controls.Button
    $del.Style = $script:HudWin.Resources['GlyphBtn']
    $del.Content = [string][char]0x2715
    $del.FontSize = 10
    $del.Width = 22
    $del.Height = 22
    $del.VerticalAlignment = 'Center'
    $del.Opacity = 0
    $del.ToolTip = 'Delete task'
    $del.Uid = $addr
    $del.add_Click({
        param($s, $e)
        $a = Get-Addr $s
        Remove-HudTask $a.sec ([int]$a.slot)
    })
    [System.Windows.Controls.DockPanel]::SetDock($del, 'Right')

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $script:HudWin.Resources['HudBox']
    $cb.BorderBrush = $script:AccentBrushObj
    $cb.IsChecked = $done
    $cb.Uid = $addr
    $cb.ToolTip = if ($done) { 'Mark as not done' } else { 'Mark as done' }
    $cb.add_Click({ param($s, $e) Complete-HudTask $s })
    [System.Windows.Controls.DockPanel]::SetDock($cb, 'Left')

    # the task text IS the editor: click it and type, no mode to enter
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Style = $script:HudWin.Resources['TaskBox']
    $tb.Text = $text
    $tb.Uid = $addr
    $tb.VerticalAlignment = 'Center'
    Set-TaskDoneStyle $tb $done
    $tb.add_LostFocus({ param($s, $e) Commit-TaskText $s })
    $tb.add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') {
            Commit-TaskText $s
            $a = Get-Addr $s
            Set-FocusByUid "$($a.sec):add"
            $e.Handled = $true
        } elseif ($e.Key -eq 'Escape') { Blur-Hud }
    })

    # the delete affordance appears only for the row under the pointer
    $row.Tag = $del
    $row.add_MouseEnter({ param($s, $e) $s.Tag.Opacity = 1 })
    $row.add_MouseLeave({ param($s, $e) $s.Tag.Opacity = 0 })

    [void]$row.Children.Add($del)
    [void]$row.Children.Add($cb)
    [void]$row.Children.Add($tb)
    $script:HudFocusables += $tb
    return $row
}

# rebuilds the HUD content (sections, tasks, edit-mode widgets); returns the pending count
function Render-HudContent {
    $note = Get-Note $script:CurrentGuid
    $script:Rendering = $true
    $script:HudTasks.Children.Clear()
    $script:HudFocusables = @()
    $secs = @($note.sections)
    $glyphStyle = $script:HudWin.Resources['GlyphBtn']
    $softStyle = $script:HudWin.Resources['SoftBtn']
    $titleStyle = $script:HudWin.Resources['TitleBox']
    $ghostStyle = $script:HudWin.Resources['GhostBox']
    $accentBrush = $script:AccentBrushObj

    for ($si = 0; $si -lt $secs.Count; $si++) {
        $sec = $secs[$si]
        $topGap = if ($si -eq 0) { 0.0 } else { 14.0 }

        # a lone untitled section needs no heading; once there are two, both get one
        if ($secs.Count -gt 1 -or ([string]$sec.title).Trim()) {
            $trow = New-Object System.Windows.Controls.DockPanel
            $trow.Margin = New-Object System.Windows.Thickness(0, $topGap, 0, 0)
            $rem = New-Object System.Windows.Controls.Button
            $rem.Style = $glyphStyle
            $rem.Content = [string][char]0x2715
            $rem.FontSize = 10
            $rem.Width = 22
            $rem.Height = 22
            $rem.Opacity = 0
            $rem.ToolTip = 'Delete this section and its tasks'
            $rem.Uid = "$($si):sec"
            $rem.add_Click({ param($s, $e) Remove-HudSection ((Get-Addr $s).sec) })
            [System.Windows.Controls.DockPanel]::SetDock($rem, 'Right')

            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Style = $titleStyle
            $tb.Text = ([string]$sec.title)
            $tb.Tag = 'section name'
            $tb.Uid = "$($si):title"
            $tb.Foreground = $accentBrush
            $tb.CaretBrush = $accentBrush
            $tb.add_LostFocus({ param($s, $e) Commit-SectionTitle $s })
            $tb.add_KeyDown({
                param($s, $e)
                if ($e.Key -eq 'Return') {
                    Commit-SectionTitle $s
                    Set-FocusByUid "$((Get-Addr $s).sec):add"
                    $e.Handled = $true
                } elseif ($e.Key -eq 'Escape') { Blur-Hud }
            })
            $script:HudFocusables += $tb

            $trow.Tag = $rem
            $trow.add_MouseEnter({ param($s, $e) $s.Tag.Opacity = 1 })
            $trow.add_MouseLeave({ param($s, $e) $s.Tag.Opacity = 0 })
            [void]$trow.Children.Add($rem)
            [void]$trow.Children.Add($tb)
            [void]$script:HudTasks.Children.Add($trow)
        }

        # rows keep their real index in the stored list, so edits address the right task
        $all = @($sec.tasks)
        for ($ti = 0; $ti -lt $all.Count; $ti++) {
            $raw = [string]$all[$ti]
            if (-not $raw) { continue }
            $isDone = $raw.TrimStart().StartsWith('x ')
            if ($isDone -and -not $script:State.settings.showDone) { continue }
            [void]$script:HudTasks.Children.Add((New-HudTaskRow $si $ti $raw $isDone))
        }

        # the always-present capture line: this is how tasks get created
        $abox = New-Object System.Windows.Controls.TextBox
        $abox.Style = $ghostStyle
        $abox.Tag = if ($all.Count) { '+  add task' } else { '+  add your first task' }
        $abox.Uid = "$($si):add"
        $abox.Margin = New-Object System.Windows.Thickness(27, 2, 0, 0)
        $abox.add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return') { Add-HudTask $s; $e.Handled = $true }
            elseif ($e.Key -eq 'Escape') { $s.Text = ''; Blur-Hud }
        })
        $script:HudFocusables += $abox
        [void]$script:HudTasks.Children.Add($abox)
    }

    # footer: add a section, and sweep away completed work when there is some
    $erow = New-Object System.Windows.Controls.StackPanel
    $erow.Orientation = 'Horizontal'
    $erow.Margin = New-Object System.Windows.Thickness(0, 10, 0, 0)
    $erow.Opacity = 0.55
    $sbtn = New-Object System.Windows.Controls.Button
    $sbtn.Style = $softStyle
    $sbtn.Content = '+ section'
    $sbtn.ToolTip = 'Group tasks under a heading'
    $sbtn.add_Click({ Add-HudSection })
    [void]$erow.Children.Add($sbtn)
    $anyDone = $false
    foreach ($s in $secs) {
        foreach ($t in @($s.tasks)) {
            if ($t -and ([string]$t).TrimStart().StartsWith('x ')) { $anyDone = $true }
        }
    }
    if ($anyDone) {
        $cbtn = New-Object System.Windows.Controls.Button
        $cbtn.Style = $softStyle
        $cbtn.Content = 'clear completed'
        $cbtn.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        $cbtn.ToolTip = 'Delete all completed tasks (undoable)'
        $cbtn.add_Click({ Clear-DoneTasks })
        [void]$erow.Children.Add($cbtn)
    }
    $erow.Tag = $erow
    $erow.add_MouseEnter({ param($s, $e) $s.Opacity = 1 })
    $erow.add_MouseLeave({ param($s, $e) $s.Opacity = 0.55 })
    [void]$script:HudTasks.Children.Add($erow)

    if ($script:UndoData -and $script:UndoData.guid -eq $script:CurrentGuid) {
        $ub = New-Object System.Windows.Controls.Border
        $ub.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(0x22, 0xFF, 0xFF, 0xFF))
        $ub.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $ub.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $ub.Padding = New-Object System.Windows.Thickness(10, 4, 4, 4)
        $ud = New-Object System.Windows.Controls.DockPanel
        $ubtn = New-Object System.Windows.Controls.Button
        $ubtn.Style = $softStyle
        $ubtn.Content = 'Undo'
        $ubtn.add_Click({ Invoke-HudUndo })
        [System.Windows.Controls.DockPanel]::SetDock($ubtn, 'Right')
        $ul = New-Object System.Windows.Controls.TextBlock
        $ul.Text = [string]$script:UndoData.label
        $ul.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Text, Segoe UI')
        $ul.FontSize = 12
        $ul.Foreground = New-Brush 0x9A 0x98 0xA4
        $ul.VerticalAlignment = 'Center'
        $ul.Margin = New-Object System.Windows.Thickness(0, 0, 10, 0)
        [void]$ud.Children.Add($ubtn)
        [void]$ud.Children.Add($ul)
        $ub.Child = $ud
        [void]$script:HudTasks.Children.Add($ub)
    }

    Update-HudProgress
    $script:Rendering = $false
    return (Get-PendingCount $note)
}

# quick capture: show the panel and drop the caret straight into the first add line
function Move-FocusToFirstAdd {
    Set-FocusByUid '0:add'
}

function Open-HudEditor {
    Show-Hud
    $script:HoldTimer.Stop()
    Move-FocusToFirstAdd
}

function Show-Hud {
    if ($script:CurrentGuid -eq [guid]::Empty) { return }
    Set-HudAccent
    $note = Get-Note $script:CurrentGuid
    $script:HudDesktop.Text = Get-DesktopName $script:CurrentGuid
    $script:HudThemeBox.Text = [string]$note.theme
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
function Set-TaskDoneStyle($tb, [bool]$done) {
    if ($done) {
        $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
        $tb.Foreground = New-Brush 0x9A 0x98 0xA4
        $tb.Opacity = 0.75
    } else {
        $tb.TextDecorations = $null
        $tb.Foreground = New-Brush 0xF5 0xF3 0xEF
        $tb.Opacity = 1.0
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
if (-not $SmokeTest) {
    if (-not $HotWin.Register(1, 0xC, 0x4E)) { Log 'WARN: Win+Shift+N registration failed' }
    if (-not $HotWin.Register(2, 0xC, 0x48)) { Log 'WARN: Win+Shift+H registration failed' }
    if (-not $HotWin.Register(3, 0xC, 0x42)) { Log 'WARN: Win+Shift+B registration failed' }
}

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
[void]$menu.Items.Add('Add task  (Win+Shift+N)', $null, { Open-HudEditor })
[void]$menu.Items.Add('Show panel  (Win+Shift+H)', $null, { Show-Hud })
[void]$menu.Items.Add('Toggle pill  (Win+Shift+B)', $null, {
    $script:State.settings.pill = -not $script:State.settings.pill
    Save-State
    Update-Pill
})
$script:TrayShowDone = New-Object System.Windows.Forms.ToolStripMenuItem('Show completed tasks')
$TrayShowDone.add_Click({ Toggle-ShowDone })
[void]$menu.Items.Add($TrayShowDone)
[void]$menu.Items.Add('Open notes folder', $null, { Start-Process explorer.exe $ScriptDir })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Exit', $null, { $script:App.Shutdown() })
$Tray.ContextMenuStrip = $menu
$Tray.add_DoubleClick({ Open-HudEditor })
Update-ShowDoneUi

# --- desktop switch polling --------------------------------------------------
$script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$PollTimer.add_Tick({
    try {
        # remember what the user was working in, so Escape can hand focus back
        $fg = [HudNative.Native]::GetForegroundWindow()
        if ($fg -ne [IntPtr]::Zero -and $fg -ne $script:HudHandle) { $script:PrevForeground = $fg }

        $g = Get-CurrentDesktopGuid
        if ($g -ne [guid]::Empty -and $g -ne $script:CurrentGuid) {
            # commit anything half-typed against the desktop it belongs to
            if ($script:HudWin.IsKeyboardFocusWithin) { [System.Windows.Input.Keyboard]::ClearFocus() }
            $script:UndoData = $null
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
    # exercises the real capture flow end to end against a throwaway notes file
    $script:SmokeStep = 0
    $script:SmokeFail = @()
    $smoke = New-Object System.Windows.Threading.DispatcherTimer
    $smoke.Interval = [TimeSpan]::FromMilliseconds(900)
    $smoke.add_Tick({
        $script:SmokeStep++
        try {
            switch ($script:SmokeStep) {
                1 { Show-Hud }
                2 {
                    # type into the ghost add-row and commit, exactly as Enter does
                    $box = $script:HudFocusables | Where-Object { $_.Uid -eq '0:add' } | Select-Object -First 1
                    if (-not $box) { $script:SmokeFail += 'no add-row rendered'; break }
                    $box.Text = 'smoke task one'
                    Add-HudTask $box
                }
                3 {
                    $note = Get-Note $script:CurrentGuid
                    if (@($note.sections[0].tasks) -notcontains 'smoke task one') { $script:SmokeFail += 'task not stored' }
                    $box2 = $script:HudFocusables | Where-Object { $_.Uid -eq '0:add' } | Select-Object -First 1
                    if (-not $box2) { $script:SmokeFail += 'add-row missing after add' }
                    elseif ($box2.Text -ne '') { $script:SmokeFail += 'add-row not cleared' }
                    # rename it in place
                    $tb = $script:HudFocusables | Where-Object { $_.Uid -like '0:*' -and $_.Text -eq 'smoke task one' } | Select-Object -First 1
                    if (-not $tb) { $script:SmokeFail += 'task row not editable'; break }
                    $tb.Text = 'smoke task renamed'
                    Commit-TaskText $tb
                }
                4 {
                    $note = Get-Note $script:CurrentGuid
                    if (@($note.sections[0].tasks) -notcontains 'smoke task renamed') { $script:SmokeFail += 'rename not stored' }
                    Add-HudSection
                }
                5 {
                    $note = Get-Note $script:CurrentGuid
                    if (@($note.sections).Count -lt 2) { $script:SmokeFail += 'section not added' }
                    $t = $script:HudFocusables | Where-Object { $_.Uid -eq '1:title' } | Select-Object -First 1
                    if (-not $t) { $script:SmokeFail += 'new section title not focusable' }
                    else { $t.Text = 'Smoke Section'; Commit-SectionTitle $t }
                }
                6 {
                    $note = Get-Note $script:CurrentGuid
                    if ([string]$note.sections[1].title -ne 'Smoke Section') { $script:SmokeFail += 'section title not stored' }
                    Remove-HudSection 1
                }
                7 {
                    if (-not $script:UndoData) { $script:SmokeFail += 'undo not offered' }
                    Invoke-HudUndo
                    $note = Get-Note $script:CurrentGuid
                    if (@($note.sections).Count -lt 2) { $script:SmokeFail += 'undo did not restore section' }
                }
                default { $script:App.Shutdown() }
            }
        } catch {
            $script:SmokeFail += "exception at step $($script:SmokeStep): $_"
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
if ($SmokeTest) {
    if ($script:SmokeFail -and $script:SmokeFail.Count) {
        Write-Host "SMOKE FAILED:"
        $script:SmokeFail | ForEach-Object { Write-Host "  - $_" }
        exit 1
    }
    Write-Host 'SMOKE OK (capture, rename, section add/delete, undo all verified)'
}
