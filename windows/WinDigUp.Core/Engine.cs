using System.ComponentModel;
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
    private readonly object _reloadGate = new();
    private CancellationTokenSource? _reloadCancellation;
    private Task? _reloadTask;
    private bool _reloadRequested;
    private long _generation;
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
            await ConfigureCoreAsync(settings);
        }
        finally { _lifecycle.Release(); }
    }

    private async Task ConfigureCoreAsync(Settings settings)
    {
        await StopAsync();
        Settings = settings;
        Directory.CreateDirectory(settings.IndexDirectory);
        var generation = Volatile.Read(ref _generation);
        _reloadCancellation = new();
        _search = new SearchClient(Launch(settings.Arguments("search-service"), "search.log"));
        _search.Event += message => Receive(message, generation);
        _monitor = new FolderMonitor(settings.Folders.Concat(settings.CodeFolders),
            () => _ = SyncSafelyAsync(generation), Warn);
        // Also catches a reconnected drive and changes made while its watcher was unavailable.
        _periodic = new Timer(_ => _ = SyncSafelyAsync(generation), null, TimeSpan.FromMinutes(5), TimeSpan.FromMinutes(5));
    }

    public async Task<JsonElement> AskAsync(object request, CancellationToken cancellation = default)
    {
        var search = _search ?? throw new InvalidOperationException("Choose folders and save settings first.");
        try
        {
            var reply = await search.AskAsync(request, cancellation);
            if (!ReferenceEquals(search, _search)) throw new OperationCanceledException("The settings changed.", cancellation);
            return reply;
        }
        catch (Exception) when (!ReferenceEquals(search, _search))
        { throw new OperationCanceledException("The settings changed.", cancellation); }
    }

    public Task SyncAsync() => SyncAsync(null);

    private async Task SyncAsync(long? generation)
    {
        await _lifecycle.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (generation is not null && generation != Volatile.Read(ref _generation)) return;
            if (Paused || Settings.Folders.Length + Settings.CodeFolders.Length == 0) return;
            if (_index is not null && !_index.Completion.IsCompleted)
            {
                await _index.SendAsync("sync");
                await _index.SendAsync("sync code");
                return;
            }
            if (_index is not null) await _index.DisposeAsync();
            var current = Volatile.Read(ref _generation);
            _index = new EventHelper(Launch(Settings.Arguments("index-service"), "index.log"), "stop",
                message => Receive(message, current));
        }
        finally { _lifecycle.Release(); }
    }

    private async Task SyncSafelyAsync(long generation)
    {
        try { await SyncAsync(generation); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception or InvalidOperationException)
        { if (!_disposed && generation == Volatile.Read(ref _generation)) Warn(error.Message); }
    }

    public async Task SetPausedAsync(bool paused)
    {
        await _lifecycle.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
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
            var generation = Volatile.Read(ref _generation);
            _download = new EventHelper(Launch(["download-model", "--to", Settings.ModelsPath], "download.log"), "",
                message => Receive(message, generation));
        }
        finally { _lifecycle.Release(); }
    }

    private HelperLaunch Launch(string[] args, string log) => new(Settings.HelperPath, args,
        Settings.HelperEnvironment(), Path.Combine(Settings.IndexDirectory, log));

    private void Warn(string message) => Event?.Invoke(JsonSerializer.SerializeToElement(new { @event = "warning", message }));
    private void Receive(JsonElement message, long generation)
    {
        if (_disposed || generation != Volatile.Read(ref _generation)) return;
        var name = message.TryGetProperty("event", out var value) ? value.GetString() : "";
        if (name == "done") { _ = ModelDownloadedAsync(message, generation); return; }
        Event?.Invoke(message);
        if (name is "file" or "idle" or "summary" or "sync") ScheduleReload(generation);
    }

    private async Task ModelDownloadedAsync(JsonElement message, long generation)
    {
        try
        {
            await _lifecycle.WaitAsync();
            try
            {
                if (_disposed || generation != Volatile.Read(ref _generation)) return;
                // search-service remembers an unavailable encoder. Replace it after installation,
                // so a search made before the download does not disable meaning search indefinitely.
                await ConfigureCoreAsync(Settings);
                generation = Volatile.Read(ref _generation);
            }
            finally { _lifecycle.Release(); }
            await SyncAsync(generation);
            if (!_disposed && generation == Volatile.Read(ref _generation)) Event?.Invoke(message);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception or InvalidOperationException)
        { if (!_disposed && generation == Volatile.Read(ref _generation)) Warn(error.Message); }
    }

    private void ScheduleReload(long generation)
    {
        lock (_reloadGate)
        {
            if (generation != Volatile.Read(ref _generation) || _search is null || _reloadCancellation is null) return;
            _reloadRequested = true;
            _reloadTask ??= ReloadAsync(_search, generation, _reloadCancellation.Token);
        }
    }

    private async Task ReloadAsync(SearchClient search, long generation, CancellationToken cancellation)
    {
        try
        {
            while (true)
            {
                // Coalesce bursts, while retaining a trailing refresh if indexing changes during a reload.
                await Task.Delay(TimeSpan.FromSeconds(2), cancellation);
                lock (_reloadGate) _reloadRequested = false;
                try
                {
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                    timeout.CancelAfter(TimeSpan.FromSeconds(30));
                    await search.AskAsync(new { op = "reload" }, timeout.Token);
                }
                catch (Exception error) when (error is IOException or JsonException or OperationCanceledException or InvalidOperationException) { }
                lock (_reloadGate)
                {
                    if (!_reloadRequested) { _reloadTask = null; return; }
                }
            }
        }
        catch (OperationCanceledException)
        { lock (_reloadGate) { if (generation == Volatile.Read(ref _generation)) _reloadTask = null; } }
    }

    private async Task StopAsync()
    {
        Interlocked.Increment(ref _generation);
        var search = _search;
        _search = null;
        Task? reload;
        var cancellation = _reloadCancellation;
        lock (_reloadGate)
        {
            cancellation?.Cancel();
            _reloadCancellation = null;
            reload = _reloadTask; _reloadTask = null; _reloadRequested = false;
        }
        if (reload is not null) await reload;
        cancellation?.Dispose();
        _monitor?.Dispose(); _monitor = null;
        _periodic?.Dispose(); _periodic = null;
        if (_index is not null) { await _index.DisposeAsync(); _index = null; }
        if (_download is not null) { await _download.DisposeAsync(); _download = null; }
        if (search is not null) await search.DisposeAsync();
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycle.WaitAsync();
        try { if (!_disposed) { _disposed = true; await StopAsync(); } }
        finally { _lifecycle.Release(); }
    }
}
