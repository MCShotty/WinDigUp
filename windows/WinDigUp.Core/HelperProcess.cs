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
        try
        {
            await using var log = Log is null ? null : new StreamWriter(
                new FileStream(Log, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false)) { AutoFlush = true };
            while (await process.StandardError.ReadLineAsync() is { } line)
                if (log is not null) await log.WriteLineAsync(line);
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException) { }
    }

    internal static async Task StopAsync(Process process, string farewell)
    {
        try
        {
            if (!process.HasExited)
            {
                await process.StandardInput.WriteLineAsync(farewell);
                process.StandardInput.Close();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                try { await process.WaitForExitAsync(timeout.Token); }
                catch (OperationCanceledException) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
            }
        }
        catch (Exception error) when (error is IOException or InvalidOperationException) { }
        finally { process.Dispose(); }
    }
}

/// A command/event helper (index-service and download-model); all its output is JSON events.
public sealed class EventHelper : IAsyncDisposable
{
    private readonly Process _process;
    private readonly Task _reader;
    private readonly string _farewell;
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
                receive(document.RootElement.Clone());
            }
            await _process.WaitForExitAsync();
            receive(JsonSerializer.SerializeToElement(new { @event = "helper_exit", exit_code = _process.ExitCode }));
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException or JsonException)
        { receive(JsonSerializer.SerializeToElement(new { @event = "error", message = error.Message })); }
    }

    public async ValueTask DisposeAsync()
    {
        await HelperLaunch.StopAsync(_process, _farewell);
        await _reader;
    }
}
