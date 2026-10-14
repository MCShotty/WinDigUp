using System.Diagnostics;
using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using WinDigUp.Core;

if (args.FirstOrDefault() == "--fake-bad-helper")
{
    Console.WriteLine(JsonSerializer.Serialize(new { @event = "started", pid = Environment.ProcessId }));
    Console.WriteLine("{invalid-json");
    await Task.Delay(30000); // A broken output stream must not leave this process alive.
    return;
}

if (args.FirstOrDefault() is "search-service" or "index-service" or "download-model")
{
    var models = Environment.GetEnvironmentVariable("DIGUP_MODELS")!;
    var versionFile = Path.Combine(models, "test-version");
    var modelFile = Path.Combine(models, "test-model");
    void Emit(string name) => Console.WriteLine(JsonSerializer.Serialize(new { @event = name }));
    if (args[0] == "index-service")
    {
        Emit("sync"); await Task.Delay(100);
        await File.WriteAllTextAsync(versionFile, "42"); Emit("file"); Emit("idle");
        while (Console.ReadLine() is { } command)
            if (command == "stop") Environment.Exit(9); // Expected stops must not report a crash.
        return;
    }
    if (args[0] == "download-model") { await File.WriteAllTextAsync(modelFile, "ready"); Emit("done"); return; }
    var version = File.ReadAllText(versionFile);
    string? encoder = null;
    while (Console.ReadLine() is { } line)
    {
        using var document = JsonDocument.Parse(line);
        var message = document.RootElement;
        var op = message.GetProperty("op").GetString();
        if (op == "quit") return;
        if (op == "reload") version = File.ReadAllText(versionFile);
        if (op == "prewarm") encoder ??= File.Exists(modelFile) ? "ready" : "unavailable";
        if (op == "slow") await Task.Delay(250);
        Console.WriteLine(JsonSerializer.Serialize(new { id = message.GetProperty("id").GetInt64(), version, encoder }));
    }
    return;
}

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
        if (message.GetProperty("op").GetString() == "stderr") Console.Error.WriteLine(new string('x', 256 * 1024));
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
    Check((await client.AskAsync(new { op = "search", q = "after restart" }, timeout.Token)).GetProperty("q").GetString() == "after restart", "helper restarts after crash");
    await client.DisposeAsync();
    try { await client.AskAsync(new { op = "search" }); throw new Exception("disposed client accepted a request"); }
    catch (ObjectDisposedException) { checks++; }

    using var regressionTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    await using (var noLog = new SearchClient(new HelperLaunch(dotnet, [assembly, "--fake-helper"],
        settings.HelperEnvironment(), folder))) // A directory cannot be opened as a log file.
    {
        await noLog.AskAsync(new { op = "stderr" }, regressionTimeout.Token);
        Check(true, "unwritable log cannot block stderr or helper replies");
    }

    var pids = new ConcurrentQueue<int>();
    await using (var broken = new SearchClient(new HelperLaunch(dotnet, [assembly, "--fake-bad-helper"], settings.HelperEnvironment())))
    {
        broken.Event += message => pids.Enqueue(message.GetProperty("pid").GetInt32());
        try
        {
            for (var i = 0; i < 2; i++)
            {
                try { await broken.AskAsync(new { op = "search" }, regressionTimeout.Token); throw new Exception("bad protocol was accepted"); }
                catch (Exception error) when (error is JsonException or IOException) { checks++; }
            }
            Check(pids.Count == 2, "broken protocol restarts a fresh helper");
            var firstPid = pids.First();
            bool running;
            try { using var process = Process.GetProcessById(firstPid); running = !process.HasExited; }
            catch (ArgumentException) { running = false; }
            Check(!running, "broken helper is terminated before replacement");
        }
        finally
        {
            foreach (var pid in pids)
                try { using var process = Process.GetProcessById(pid); if (!process.HasExited) process.Kill(true); }
                catch (ArgumentException) { }
        }
    }

    // Run the real Engine against executable helpers with the CLI's event/request behavior.
    // The fake helper never opens the app's index database; fixture files stay in this temporary folder.
    Environment.SetEnvironmentVariable("DOTNET_ROOT", Path.GetDirectoryName(dotnet));
    var watched = Path.Combine(folder, "watched");
    var models = Path.Combine(folder, "models");
    Directory.CreateDirectory(watched); Directory.CreateDirectory(models);
    await File.WriteAllTextAsync(Path.Combine(models, "test-version"), "0");
    var engineSettings = new Settings
    {
        HelperPath = Path.Combine(AppContext.BaseDirectory, Path.GetFileNameWithoutExtension(assembly)
            + (OperatingSystem.IsWindows() ? ".exe" : "")),
        ModelsPath = models, Folders = [watched]
    };
    var engineEvents = new ConcurrentQueue<JsonElement>();
    var idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    await using (var engine = new Engine())
    {
        engine.Event += message =>
        {
            engineEvents.Enqueue(message);
            var name = message.GetProperty("event").GetString();
            if (name == "idle") idle.TrySetResult();
            if (name == "done") done.TrySetResult();
        };
        await engine.ConfigureAsync(engineSettings);
        Check((await engine.AskAsync(new { op = "prewarm" }, regressionTimeout.Token)).GetProperty("encoder").GetString() == "unavailable", "fixture encoder fails before download");
        await engine.SyncAsync();
        await idle.Task.WaitAsync(regressionTimeout.Token);
        using (var refreshTimeout = CancellationTokenSource.CreateLinkedTokenSource(regressionTimeout.Token))
        {
            refreshTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            while ((await engine.AskAsync(new { op = "status" }, refreshTimeout.Token)).GetProperty("version").GetString() != "42")
                await Task.Delay(100, refreshTimeout.Token);
        }
        Check(true, "final index event gets a trailing reload");
        await engine.DownloadAsync();
        await done.Task.WaitAsync(regressionTimeout.Token);
        Check((await engine.AskAsync(new { op = "prewarm" }, regressionTimeout.Token)).GetProperty("encoder").GetString() == "ready", "model download recovers unavailable encoder");
        await engine.SetPausedAsync(true);
        Check(!engineEvents.Any(message => message.GetProperty("event").GetString() is "error" or "warning"
            || message.GetProperty("event").GetString() == "helper_exit" && message.GetProperty("exit_code").GetInt32() != 0), "intentional helper stops do not show crash errors");
        var stale = engine.AskAsync(new { op = "slow" }, regressionTimeout.Token);
        await engine.ConfigureAsync(engineSettings);
        try { await stale; throw new Exception("old configuration returned a reply"); }
        catch (OperationCanceledException) { checks++; }
        await engine.DisposeAsync();
        try { await engine.SetPausedAsync(false); throw new Exception("disposed engine accepted resume"); }
        catch (ObjectDisposedException) { checks++; }
    }
    Console.WriteLine($"PASS: {checks} Windows core and helper integration checks");
}
finally { Directory.Delete(folder, recursive: true); }
