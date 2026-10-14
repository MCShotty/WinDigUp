using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using WinDigUp.Core;
using Windows.Storage.Pickers;
using Windows.System;

namespace WinDigUp;

public sealed partial class MainWindow : Window
{
    private readonly Engine _engine = new();
    private Settings _settings = new();
    private readonly ObservableCollection<string> _folders = [], _codeFolders = [];
    private readonly ObservableCollection<SearchHit> _hits = [];
    private readonly string _settingsFile = Path.Combine(Settings.DataDirectory, "settings.json");
    private readonly nint _handle;
    private NativeDesktop? _desktop;
    private CancellationTokenSource? _queryCancellation, _previewCancellation;
    private bool _loaded, _quitting, _configured;
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    public MainWindow()
    {
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        _handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1060, 780));
        AppWindow.Closing += (_, args) => { if (!_quitting) { args.Cancel = true; _desktop?.Hide(); } };
        Folders.ItemsSource = _folders; CodeFolders.ItemsSource = _codeFolders; Results.ItemsSource = _hits;
        Logo.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "logo.png")));
        _engine.Event += message => DispatcherQueue.TryEnqueue(() => Receive(message));
    }

    private async void Loaded(object sender, RoutedEventArgs args)
    {
        if (_loaded) return;
        _loaded = true;
        _desktop = new NativeDesktop(_handle, action => DispatcherQueue.TryEnqueue(() => DesktopAction(action)));
        await Run(async () =>
        {
            _settings = await SettingsStore.LoadAsync(_settingsFile);
            FillSettings();
            if (_folders.Count + _codeFolders.Count == 0) { SettingsPanel.IsExpanded = true; return; }
            await _engine.ConfigureAsync(_settings); _configured = true;
            await _engine.SyncAsync();
        });
        if (!_desktop.HotkeyRegistered) ShowNotice("Ctrl+Shift+Space is already in use. You can open WinDigUp from the tray.");
        Query.Focus(FocusState.Programmatic);
    }

    private void FillSettings()
    {
        _folders.Clear(); foreach (var path in _settings.Folders) _folders.Add(path);
        _codeFolders.Clear(); foreach (var path in _settings.CodeFolders) _codeFolders.Add(path);
        Acceleration.SelectedIndex = (int)_settings.Backend;
        HelperPath.Text = _settings.HelperPath; ModelsPath.Text = _settings.ModelsPath;
        OpenVinoPython.Text = _settings.OpenVinoPython; OpenVinoModels.Text = _settings.OpenVinoModels;
        CodeEditor.Text = _settings.CodeEditor;
        SkipTypes.Text = string.Join(", ", _settings.ExcludedExtensions);
        SkippedFolders.Text = string.Join(Environment.NewLine, _settings.SkippedFolders);
    }

    private Settings ReadSettings() => _settings with
    {
        Folders = [.. _folders], CodeFolders = [.. _codeFolders], Backend = (Backend)Acceleration.SelectedIndex,
        HelperPath = HelperPath.Text.Trim(), ModelsPath = ModelsPath.Text.Trim(),
        OpenVinoPython = OpenVinoPython.Text.Trim(), OpenVinoModels = OpenVinoModels.Text.Trim(), CodeEditor = CodeEditor.Text.Trim(),
        ExcludedExtensions = SkipTypes.Text.Split([',', ' ', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(value => value.TrimStart('.', '*').ToLowerInvariant()).ToArray(),
        SkippedFolders = SkippedFolders.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    };

    private async void SaveClick(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        SaveSettings.IsEnabled = false;
        try
        {
            var settings = ReadSettings();
            await _engine.ConfigureAsync(settings);
            await SettingsStore.SaveAsync(settings, _settingsFile);
            _settings = settings; _configured = true; SettingsPanel.IsExpanded = false; Notice.IsOpen = false;
            await _engine.SyncAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            await _engine.AskAsync(new { op = "prewarm" }, timeout.Token);
        }
        finally { SaveSettings.IsEnabled = true; }
    });

    private async Task PickFolder(ObservableCollection<string> list)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, _handle);
        if (await picker.PickSingleFolderAsync() is { } folder && !list.Contains(folder.Path, StringComparer.OrdinalIgnoreCase)) list.Add(folder.Path);
    }
    private async void AddFolderClick(object sender, RoutedEventArgs args) => await Run(() => PickFolder(_folders));
    private async void AddCodeFolderClick(object sender, RoutedEventArgs args) => await Run(() => PickFolder(_codeFolders));
    private void RemoveFolderClick(object sender, RoutedEventArgs args) { if (Folders.SelectedItem is string path) _folders.Remove(path); }
    private void RemoveCodeFolderClick(object sender, RoutedEventArgs args) { if (CodeFolders.SelectedItem is string path) _codeFolders.Remove(path); }
    private void SettingsClick(object sender, RoutedEventArgs args) => SettingsPanel.IsExpanded = !SettingsPanel.IsExpanded;
    private async void DownloadClick(object sender, RoutedEventArgs args) => await Run(async () =>
    {
        if (!_configured) { await _engine.ConfigureAsync(ReadSettings()); _configured = true; }
        await _engine.DownloadAsync();
    });
    private async void SyncClick(object sender, RoutedEventArgs args) => await Run(() => _engine.SyncAsync());
    private async void PauseClick(object sender, RoutedEventArgs args) => await Run(TogglePause);
    private async Task TogglePause()
    {
        await _engine.SetPausedAsync(!_engine.Paused);
        Pause.Content = _engine.Paused ? "Resume indexing" : "Pause indexing";
        Status.Text = _engine.Paused ? "Indexing paused. Search remains available." : "Indexing resumed.";
    }

    private void QueryChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        if (_loaded && args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) ScheduleSearch();
    }
    private void FilterChanged(object sender, SelectionChangedEventArgs args) { if (_loaded) ScheduleSearch(); }
    private void ScheduleSearch()
    {
        _queryCancellation?.Cancel(); _queryCancellation?.Dispose();
        _queryCancellation = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        _ = SearchAsync(_queryCancellation.Token);
    }
    private async Task SearchAsync(CancellationToken cancellation)
    {
        try
        {
            await Task.Delay(300, cancellation);
            var text = Query.Text.Trim();
            if (text.Length == 0) { _hits.Clear(); return; }
            var code = text.StartsWith("code:", StringComparison.OrdinalIgnoreCase);
            if (code) text = text[5..].Trim();
            var filter = (KindFilter.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
            var reply = await _engine.AskAsync(new
            {
                op = "search", q = text, code, meaning = true, limit = 60,
                kinds = filter.Length == 0 ? null : filter.Split(',')
            }, cancellation);
            cancellation.ThrowIfCancellationRequested();
            var hits = reply.GetProperty("hits").Deserialize<SearchHit[]>(Json) ?? [];
            _hits.Clear(); foreach (var hit in hits) _hits.Add(hit);
            var meaning = reply.TryGetProperty("meaning", out var mode) && mode.GetBoolean();
            Status.Text = $"{hits.Length} results · {(meaning ? "meaning + exact words" : "exact words")}";
            if (reply.TryGetProperty("warning", out var warning)) ShowNotice(warning.GetString() ?? "");
            if (hits.Length == 0) PreviewText.Text = "No matches yet. Check your folders or let indexing finish.";
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { ShowNotice(error.Message); }
    }

    private void QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (Results.SelectedItem is SearchHit hit) Open(hit); else ScheduleSearch();
    }
    private async void ResultSelected(object sender, SelectionChangedEventArgs args)
    {
        _previewCancellation?.Cancel(); _previewCancellation?.Dispose();
        _previewCancellation = new(TimeSpan.FromSeconds(45));
        if (Results.SelectedItem is not SearchHit hit) return;
        PreviewTitle.Text = hit.Name; PreviewImage.Source = null; PreviewText.Text = hit.Detail;
        var cancellation = _previewCancellation.Token;
        await Run(async () =>
        {
            var code = hit.Kind == "code";
            var text = await _engine.AskAsync(new { op = "text", segment = hit.SegmentId, code }, cancellation);
            cancellation.ThrowIfCancellationRequested();
            PreviewText.Text = text.TryGetProperty("text", out var passage) && passage.ValueKind == JsonValueKind.String
                ? passage.GetString() : hit.Detail;
            if (hit.Kind is "image" or "screenshot" or "pdf" or "video")
            {
                var rendered = await _engine.AskAsync(new { op = "render", path = hit.Path,
                    kind = hit.Kind == "screenshot" ? "image" : hit.Kind, loc = hit.Loc ?? 0, pixels = 600 }, cancellation);
                cancellation.ThrowIfCancellationRequested();
                if (rendered.TryGetProperty("image", out var image) && image.ValueKind == JsonValueKind.String)
                    PreviewImage.Source = new BitmapImage(new Uri(image.GetString()!));
            }
        });
    }

    private void ResultClicked(object sender, ItemClickEventArgs args) { if (args.ClickedItem is SearchHit hit) Results.SelectedItem = hit; }
    private void OpenClick(object sender, RoutedEventArgs args) { if (Results.SelectedItem is SearchHit hit) Open(hit); }
    private void RevealClick(object sender, RoutedEventArgs args) { if (Results.SelectedItem is SearchHit hit) Reveal(hit); }
    private void Open(SearchHit hit)
    {
        try
        {
            if (!File.Exists(hit.Path)) throw new FileNotFoundException("This file is currently unavailable.", hit.Path);
            if (hit.Kind == "code" && File.Exists(_settings.CodeEditor))
            {
                var start = new ProcessStartInfo(_settings.CodeEditor) { UseShellExecute = false };
                start.ArgumentList.Add("--goto"); start.ArgumentList.Add($"{hit.Path}:{hit.Loc ?? 1:0}"); Process.Start(start);
            }
            else
            {
                var vlc = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "VideoLAN", "VLC", "vlc.exe");
                if (hit.Kind is "audio" or "video" && hit.Loc is { } seconds && File.Exists(vlc))
                {
                    var start = new ProcessStartInfo(vlc) { UseShellExecute = false };
                    start.ArgumentList.Add("--start-time=" + seconds.ToString(System.Globalization.CultureInfo.InvariantCulture));
                    start.ArgumentList.Add(hit.Path); Process.Start(start);
                }
                else Process.Start(new ProcessStartInfo(hit.Path) { UseShellExecute = true });
            }
        }
        catch (Exception error) { ShowNotice(error.Message); }
    }
    private void Reveal(SearchHit hit)
    {
        var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        start.ArgumentList.Add("/select,"); start.ArgumentList.Add(hit.Path);
        try { Process.Start(start); } catch (Exception error) { ShowNotice(error.Message); }
    }

    private void KeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape) { _desktop?.Hide(); args.Handled = true; }
        if (args.Key is VirtualKey.Down or VirtualKey.Up && _hits.Count > 0)
        {
            Results.SelectedIndex = Math.Clamp(Results.SelectedIndex + (args.Key == VirtualKey.Down ? 1 : -1), 0, _hits.Count - 1);
            Results.ScrollIntoView(Results.SelectedItem); args.Handled = true;
        }
        if (args.Key == VirtualKey.Enter && Results.SelectedItem is SearchHit hit) { Open(hit); args.Handled = true; }
    }

    private void Receive(JsonElement message)
    {
        if (_quitting || !message.TryGetProperty("event", out var type)) return;
        switch (type.GetString())
        {
            case "encoder":
                DeviceStatus.Text = message.TryGetProperty("accelerator", out var device) ? $"EmbeddingGemma 2 · {device.GetString()}"
                    : $"Encoder: {message.GetProperty("state").GetString()}";
                if (message.TryGetProperty("error", out var failure)) ShowNotice(failure.GetString() ?? "Encoder unavailable.");
                break;
            case "error": case "warning":
                ShowNotice(message.TryGetProperty("message", out var error) ? error.GetString() ?? "" : message.ToString()); break;
            case "waiting": Status.Text = "Waiting for the model. Download it in settings."; break;
            case "idle": Status.Text = "Index up to date."; break;
            case "file": Status.Text = message.TryGetProperty("path", out var path) ? $"Indexing {Path.GetFileName(path.GetString())}" : "Indexing…"; break;
            case "progress":
                Status.Text = message.TryGetProperty("bytes", out var bytes) ? $"Downloading model · {bytes.GetInt64() / (1 << 20)} MB" : "Downloading model…"; break;
            case "done": Status.Text = "Model ready. Indexing your folders."; break;
            case "helper_exit":
                if (message.GetProperty("exit_code").GetInt32() != 0) ShowNotice("A helper stopped. Check the logs in " + _settings.IndexDirectory);
                break;
        }
    }

    private async void DesktopAction(string action)
    {
        if (action is "show" or "settings") { _desktop?.Show(); Activate(); Query.Focus(FocusState.Programmatic); }
        if (action == "settings") SettingsPanel.IsExpanded = true;
        if (action == "pause") await Run(TogglePause);
        if (action == "quit") await QuitAsync();
    }
    private async void QuitClick(object sender, RoutedEventArgs args) => await QuitAsync();
    private async Task QuitAsync()
    {
        if (_quitting) return;
        _quitting = true; _queryCancellation?.Cancel(); _previewCancellation?.Cancel();
        _desktop?.Dispose(); await _engine.DisposeAsync(); Close(); Application.Current.Exit();
    }
    private async Task Run(Func<Task> work)
    {
        try { await work(); }
        catch (OperationCanceledException) { }
        catch (Exception error) { ShowNotice(error.Message); }
    }
    private void ShowNotice(string message) { Notice.Message = message; Notice.Severity = InfoBarSeverity.Warning; Notice.IsOpen = true; }
}
