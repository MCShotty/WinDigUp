namespace WinDigUp.Core;

public sealed class FolderMonitor : IDisposable
{
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly Timer _timer;
    private readonly Action _changed;
    private bool _disposed;
    private readonly object _gate = new();

    public FolderMonitor(IEnumerable<string> folders, Action changed, Action<string> warning)
    {
        _changed = changed;
        _timer = new(_ => { lock (_gate) { if (!_disposed) _changed(); } }, null, Timeout.Infinite, Timeout.Infinite);
        foreach (var folder in folders.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(folder)) { warning($"Folder unavailable: {folder}"); continue; }
            try
            {
                var watcher = new FileSystemWatcher(folder)
                {
                    IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName
                        | NotifyFilters.LastWrite | NotifyFilters.Size, InternalBufferSize = 32768
                };
                watcher.Created += Changed; watcher.Changed += Changed; watcher.Deleted += Changed; watcher.Renamed += Changed;
                watcher.Error += (_, _) => Schedule(); // Overflow requires a full sync too.
                watcher.EnableRaisingEvents = true;
                _watchers.Add(watcher);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            { warning($"Cannot watch {folder}: {error.Message}"); }
        }
    }

    private void Changed(object sender, FileSystemEventArgs args) => Schedule();
    private void Schedule() { lock (_gate) { if (!_disposed) _timer.Change(2000, Timeout.Infinite); } }
    public void Dispose()
    {
        lock (_gate) { _disposed = true; _timer.Dispose(); }
        foreach (var watcher in _watchers) watcher.Dispose();
    }
}
