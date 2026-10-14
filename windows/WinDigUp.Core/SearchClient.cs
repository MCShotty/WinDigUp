using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;

namespace WinDigUp.Core;

/// Owns a single generation of search-service. Concurrent callers receive only their own replies.
public sealed class SearchClient(HelperLaunch launch) : IAsyncDisposable
{
    private readonly SemaphoreSlim _write = new(1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> _pending = new();
    private Process? _process;
    private Task? _reader;
    private long _nextId;
    private bool _disposed;
    public event Action<JsonElement>? Event;

    public async Task<JsonElement> AskAsync(object request, CancellationToken cancellation = default)
    {
        var id = Interlocked.Increment(ref _nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = cancellation.Register(() =>
        {
            if (_pending.TryRemove(id, out var pending)) pending.TrySetCanceled(cancellation);
        });
        await _write.WaitAsync(cancellation);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            cancellation.ThrowIfCancellationRequested();
            if (_process is null || _process.HasExited || _reader?.IsCompleted == true)
            {
                // Await the old reader before starting again: its failure must not reach the new generation.
                if (_reader is not null) await _reader;
                _process?.Dispose();
                _process = launch.Start();
                _reader = ReadAsync(_process);
            }
            _pending[id] = completion;
            var message = JsonSerializer.SerializeToNode(request)!.AsObject();
            message["id"] = id;
            await _process.StandardInput.WriteLineAsync(message.ToJsonString());
            await _process.StandardInput.FlushAsync(cancellation);
        }
        catch
        {
            _pending.TryRemove(id, out _);
            throw;
        }
        finally { _write.Release(); }
        // Covers cancellation between registration and insertion into _pending.
        try
        {
            var reply = await completion.Task.WaitAsync(cancellation);
            if (reply.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.False)
                throw new IOException(reply.TryGetProperty("error", out var error) ? error.GetString() : "The helper failed.");
            return reply;
        }
        finally { _pending.TryRemove(id, out _); }
    }

    private async Task ReadAsync(Process process)
    {
        Exception failure = new IOException("DigUp's search helper stopped. The next search will restart it.");
        try
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                using var document = JsonDocument.Parse(line);
                var message = document.RootElement.Clone();
                if (message.TryGetProperty("id", out var id) && id.TryGetInt64(out var number))
                {
                    if (_pending.TryRemove(number, out var pending)) pending.TrySetResult(message);
                }
                else Event?.Invoke(message);
            }
        }
        catch (Exception error) when (error is IOException or JsonException or ObjectDisposedException or InvalidOperationException)
        { failure = error; }
        finally
        {
            foreach (var id in _pending.Keys)
                if (_pending.TryRemove(id, out var pending)) pending.TrySetException(failure);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _write.WaitAsync();
        try
        {
            if (_disposed) return;
            _disposed = true;
            if (_process is not null) await HelperLaunch.StopAsync(_process, "{\"op\":\"quit\"}");
            if (_reader is not null) await _reader;
        }
        finally { _write.Release(); }
    }
}
