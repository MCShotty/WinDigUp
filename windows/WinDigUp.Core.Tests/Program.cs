using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using WinDigUp.Core;

if (args.FirstOrDefault() == "--fake-helper")
{
    Console.WriteLine("{\"event\":\"encoder\",\"state\":\"ready\"}");
    while (Console.ReadLine() is { } line)
    {
        using var document = JsonDocument.Parse(line);
        var message = document.RootElement;
        if (message.GetProperty("op").GetString() == "quit") break;
        if (message.GetProperty("op").GetString() == "crash") Environment.Exit(7);
        if (message.GetProperty("op").GetString() == "slow") await Task.Delay(250);
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            id = message.GetProperty("id").GetInt64(), ok = true,
            q = message.TryGetProperty("q", out var query) ? query.GetString() : "",
            backend = Environment.GetEnvironmentVariable("DIGUP_BACKEND"),
            argument = args.ElementAtOrDefault(1)
        }));
    }
    return;
}

var checks = 0;
void Check(bool condition, string label)
{
    if (!condition) throw new Exception("FAILED: " + label);
    checks++;
}

var folder = Path.Combine(Path.GetTempPath(), "WinDigUp tests " + Guid.NewGuid());
Directory.CreateDirectory(folder);
try
{
    var settings = new Settings { Folders = [@"C:\ملفات\my projects"], CodeFolders = [@"D:\code"], Backend = Backend.Amd };
    Check(settings.HelperEnvironment()["DIGUP_BACKEND"] == "amd", "AMD environment");
    Check(settings.Arguments("search-service").Contains(@"C:\ملفات\my projects"), "Unicode argument remains one value");
    Check(settings.Arguments("index-service").Contains("--backfill"), "index service backfill");
    Check(settings.Arguments("index-service").Contains("--code-root"), "code folders passed");
    Check(settings.IndexDirectory != (settings with { Backend = Backend.OpenVinoNpu }).IndexDirectory, "vector stores separated");
    Check((settings with { Backend = Backend.Nvidia }).IndexDirectory == settings.IndexDirectory, "llama vector store shared");
    var path = Path.Combine(folder, "settings.json");
    await SettingsStore.SaveAsync(settings, path);
    var loaded = await SettingsStore.LoadAsync(path);
    Check(loaded.Folders.SequenceEqual(settings.Folders) && loaded.Backend == Backend.Amd, "settings round trip");
    await SettingsStore.SaveAsync(settings with { Backend = Backend.Cpu }, path);
    Check((await SettingsStore.LoadAsync(path)).Backend == Backend.Cpu, "settings replace existing file");
    Check(!Directory.EnumerateFiles(folder, "*.tmp").Any(), "settings clean temporary files");
    var hit = JsonSerializer.Deserialize<SearchHit>("{\"Path\":\"C:/a.pdf\",\"Kind\":\"pdf\",\"Loc\":3,\"segment_id\":42,\"Info\":{\"pages\":\"10\"}}");
    Check(hit?.Info["pages"] == "10" && hit.SegmentId == 42 && hit.Detail.Contains("page 3"), "upstream hit metadata contract");

    var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? Path.GetFullPath(Path.Combine(
        RuntimeEnvironment.GetRuntimeDirectory(), "..", "..", "..", OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet"));
    var assembly = Assembly.GetExecutingAssembly().Location;
    var literal = "space العربية \"quote\" $(`literal`)";
    await using var client = new SearchClient(new HelperLaunch(dotnet, [assembly, "--fake-helper", literal], settings.HelperEnvironment()));
    var events = 0;
    client.Event += _ => Interlocked.Increment(ref events);
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    var replies = await Task.WhenAll(Enumerable.Range(0, 20).Select(async i =>
        await client.AskAsync(new { op = "search", q = "query " + i }, timeout.Token)));
    Check(replies.Select(reply => reply.GetProperty("q").GetString()).SequenceEqual(Enumerable.Range(0, 20).Select(i => "query " + i)), "concurrent request routing");
    Check(replies.All(reply => reply.GetProperty("backend").GetString() == "amd"), "backend propagated to child");
    Check(replies[0].GetProperty("argument").GetString() == literal, "argument passing without a shell");
    Check(events == 1, "events do not consume request replies");
    using (var cancel = new CancellationTokenSource(50))
    {
        try { await client.AskAsync(new { op = "slow" }, cancel.Token); throw new Exception("cancel did not stop waiting"); }
        catch (OperationCanceledException) { checks++; }
    }
    Check((await client.AskAsync(new { op = "search", q = "after cancellation" }, timeout.Token)).GetProperty("q").GetString() == "after cancellation", "late reply cannot poison next query");
    try { await client.AskAsync(new { op = "crash" }, timeout.Token); throw new Exception("crash was not reported"); }
    catch (IOException) { checks++; }
    // Reader completion and process exit can be separated by a few milliseconds.
    await Task.Delay(50);
    Check((await client.AskAsync(new { op = "search", q = "after restart" }, timeout.Token)).GetProperty("q").GetString() == "after restart", "helper restarts after crash");
    await client.DisposeAsync();
    try { await client.AskAsync(new { op = "search" }); throw new Exception("disposed client accepted a request"); }
    catch (ObjectDisposedException) { checks++; }
    Console.WriteLine($"PASS: {checks} Windows core and helper integration checks");
}
finally { Directory.Delete(folder, recursive: true); }
