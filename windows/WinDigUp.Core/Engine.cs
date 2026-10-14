using System.Text.Json;

namespace WinDigUp.Core;

public sealed class Engine : IAsyncDisposable
{
    private readonly SemaphoreSlim _lifecycle = new(1);
    private SearchClient? _search;
    private EventHelper? _index;
    private EventHelper? _download;
    private FolderMonitor? _monitor;
    private Timer? _periodic;
    private bool _disposed;
    private DateTime _lastReload = DateTime.MinValue;
    public Settings Settings { get; private set; } = new();
    public bool Paused { get; private set; }
    public event Action<JsonElement>? Event;

    public async Task ConfigureAsync(Settings settings)
    {
        settings.Validate();
        await _lifecycle.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            await StopAsync();
            Settings = settings;
            Directory.CreateDirectory(settings.IndexDirectory);
            _search = new SearchClient(Launch(settings.Arguments("search-service"), "search.log"));
            _search.Event += Receive;
            _monitor = new FolderMonitor(settings.Folders.Concat(settings.CodeFolders),
                () => _ = SyncSafelyAsync(), Warn);
            // Also catches a reconnected drive and changes made while its watcher was unavailable.
            _periodic = new Timer(_ => _ = SyncSafelyAsync(), null, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(5));
        }
        finally { _lifecycle.Release(); }
    }

    public Task<JsonElement> AskAsync(object request, CancellationToken cancellation = default) =>
        (_search ?? throw new InvalidOperationException("Choose folders and save settings first.")).AskAsync(request, cancellation);

    public async Task SyncAsync()
    {
        await _lifecycle.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (Paused || Settings.Folders.Length + Settings.CodeFolders.Length == 0) return;
            if (_index is not null && !_index.Completion.IsCompleted)
            {
                await _index.SendAsync("sync");
                await _index.SendAsync("sync code");
                return;
            }
            if (_index is not null) await _index.DisposeAsync();
            _index = new EventHelper(Launch(Settings.Arguments("index-service"), "index.log"), "stop", Receive);
        }
        finally { _lifecycle.Release(); }
    }

    private async Task SyncSafelyAsync()
    {
        try { await SyncAsync(); }
        catch (Exception error) when (error is IOException or InvalidOperationException or ObjectDisposedException)
        { if (!_disposed) Warn(error.Message); }
    }

    public async Task SetPausedAsync(bool paused)
    {
        await _lifecycle.WaitAsync();
        try
        {
            Paused = paused;
            if (paused && _index is not null) { await _index.DisposeAsync(); _index = null; }
        }
        finally { _lifecycle.Release(); }
        if (!paused) await SyncAsync();
    }

    public async Task DownloadAsync()
    {
        await _lifecycle.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (Settings.Backend == Backend.OpenVinoNpu)
                throw new InvalidOperationException("OpenVINO uses a locally exported bundle. Run worker/windows/export_openvino.py.");
            if (_download is not null && !_download.Completion.IsCompleted) return;
            if (_download is not null) await _download.DisposeAsync();
            _download = new EventHelper(Launch(["download-model", "--to", Settings.ModelsPath], "download.log"), "", Receive);
        }
        finally { _lifecycle.Release(); }
    }

    private HelperLaunch Launch(string[] args, string log) => new(Settings.HelperPath, args,
        Settings.HelperEnvironment(), Path.Combine(Settings.IndexDirectory, log));

    private void Warn(string message) => Event?.Invoke(JsonSerializer.SerializeToElement(new { @event = "warning", message }));
    private void Receive(JsonElement message)
    {
        Event?.Invoke(message);
        var name = message.TryGetProperty("event", out var value) ? value.GetString() : "";
        if (name == "done") _ = SyncSafelyAsync();
        if (name is "file" or "idle" or "summary" or "sync") _ = ReloadSafelyAsync();
    }

    private async Task ReloadSafelyAsync()
    {
        if (DateTime.UtcNow - _lastReload < TimeSpan.FromSeconds(2)) return;
        _lastReload = DateTime.UtcNow;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await AskAsync(new { op = "reload" }, timeout.Token);
        }
        catch (Exception error) when (error is IOException or OperationCanceledException or InvalidOperationException or ObjectDisposedException)
        { }
    }

    private async Task StopAsync()
    {
        _monitor?.Dispose(); _monitor = null;
        _periodic?.Dispose(); _periodic = null;
        if (_index is not null) { await _index.DisposeAsync(); _index = null; }
        if (_download is not null) { await _download.DisposeAsync(); _download = null; }
        if (_search is not null) { await _search.DisposeAsync(); _search = null; }
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycle.WaitAsync();
        try { if (!_disposed) { _disposed = true; await StopAsync(); } }
        finally { _lifecycle.Release(); }
    }
}
