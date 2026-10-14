using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace WinDigUp.Core;

public sealed record HelperLaunch(string Executable, IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string> Environment, string? Log = null)
{
    public Process Start()
    {
        var start = new ProcessStartInfo(Executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        // ArgumentList handles spaces, Unicode, quotes and drive letters without a command shell.
        foreach (var argument in Arguments) start.ArgumentList.Add(argument);
        foreach (var (key, value) in Environment) start.Environment[key] = value;
        var process = Process.Start(start) ?? throw new IOException("Could not start DigUp's helper.");
        _ = DrainErrorsAsync(process);
        return process;
    }

    private async Task DrainErrorsAsync(Process process)
    {
        StreamWriter? log = null;
        try
        {
            if (Log is not null)
            {
                try { log = new StreamWriter(new FileStream(Log, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
                    new UTF8Encoding(false)) { AutoFlush = true }; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
            // A missing/unwritable log must never stop draining the pipe and block the helper.
            while (await process.StandardError.ReadLineAsync() is { } line)
                if (log is not null)
                {
                    try { await log.WriteLineAsync(line); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                    {
                        try { await log.DisposeAsync(); } catch (IOException) { }
                        log = null;
                    }
                }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException) { }
        finally { if (log is not null) { try { await log.DisposeAsync(); } catch (IOException) { } } }
    }

    internal static async Task StopAsync(Process process, string farewell)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            if (!process.HasExited)
            {
                try
                {
                    await process.StandardInput.WriteLineAsync(farewell.AsMemory(), timeout.Token).WaitAsync(timeout.Token);
                    process.StandardInput.Close();
                }
                catch (Exception error) when (error is IOException or InvalidOperationException or OperationCanceledException) { }
                try { await process.WaitForExitAsync(timeout.Token); }
                catch (OperationCanceledException) { await AbortAsync(process); }
            }
        }
        catch (InvalidOperationException) { }
    }

    internal static async Task AbortAsync(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
        }
        catch (InvalidOperationException) { }
    }
}

/// A command/event helper (index-service and download-model); all its output is JSON events.
public sealed class EventHelper : IAsyncDisposable
{
    private readonly Process _process;
    private readonly Task _reader;
    private readonly string _farewell;
    private int _stopping;
    public Task Completion => _reader;
    public async Task SendAsync(string command)
    {
        await _process.StandardInput.WriteLineAsync(command);
        await _process.StandardInput.FlushAsync();
    }

    public EventHelper(HelperLaunch launch, string farewell, Action<JsonElement> receive)
    {
        _process = launch.Start();
        _farewell = farewell;
        _reader = ReadAsync(receive);
    }

    private async Task ReadAsync(Action<JsonElement> receive)
    {
        try
        {
            while (await _process.StandardOutput.ReadLineAsync() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                using var document = JsonDocument.Parse(line);
                if (Volatile.Read(ref _stopping) == 0) receive(document.RootElement.Clone());
            }
            await _process.WaitForExitAsync();
            if (Volatile.Read(ref _stopping) == 0)
                receive(JsonSerializer.SerializeToElement(new { @event = "helper_exit", exit_code = _process.ExitCode }));
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException or JsonException)
        {
            if (Volatile.Read(ref _stopping) == 0)
            {
                receive(JsonSerializer.SerializeToElement(new { @event = "error", message = error.Message }));
                await HelperLaunch.AbortAsync(_process);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _stopping, 1) == 0) await HelperLaunch.StopAsync(_process, _farewell);
        try { await _reader; }
        finally { _process.Dispose(); }
    }
}
