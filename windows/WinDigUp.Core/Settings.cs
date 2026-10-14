using System.Text.Json;
using System.Text.Json.Serialization;

namespace WinDigUp.Core;

[JsonConverter(typeof(JsonStringEnumConverter<Backend>))]
public enum Backend { Auto, Cpu, Nvidia, Amd, OpenVinoNpu }

public sealed record Settings
{
    public string[] Folders { get; init; } = [];
    public string[] SkippedFolders { get; init; } = [];
    public string[] ExcludedExtensions { get; init; } = [];
    public string[] CodeFolders { get; init; } = [];
    public string[] CodeSkippedFolders { get; init; } = [];
    public Backend Backend { get; init; } = Backend.Auto;
    public string HelperPath { get; init; } = Path.Combine(AppContext.BaseDirectory, "helper", "digup.exe");
    public string ModelsPath { get; init; } = Path.Combine(DataDirectory, "Models");
    public string OpenVinoPython { get; init; } = "";
    public string OpenVinoModels { get; init; } = "";
    public string OpenVinoWorker { get; init; } = Path.Combine(AppContext.BaseDirectory, "worker", "openvino_worker.py");
    public string CodeEditor { get; init; } = "";
    public static string DataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinDigUp");

    // OpenVINO and llama.cpp produce different vector contracts. Separate stores let people switch
    // devices without temporarily comparing vectors from one runtime to a query from another.
    public string IndexDirectory => Path.Combine(DataDirectory, "index", Backend == Backend.OpenVinoNpu ? "openvino" : "llama");

    public void Validate()
    {
        if (!Enum.IsDefined(Backend)) throw new ArgumentException("Choose an available acceleration mode.");
        if (!File.Exists(HelperPath)) throw new FileNotFoundException("DigUp's helper is missing. Build it with scripts/build-windows.ps1.", HelperPath);
        if (Folders.Concat(CodeFolders).Any(path => !Path.IsPathFullyQualified(path)))
            throw new ArgumentException("Choose folders using their full paths.");
        if (Backend == Backend.OpenVinoNpu && (!File.Exists(OpenVinoPython) || !File.Exists(OpenVinoWorker)
            || !File.Exists(Path.Combine(OpenVinoModels, "digup-openvino.json"))))
            throw new ArgumentException("Select OpenVINO's Python executable and an exported model bundle first. See windows/README.md.");
    }

    public Dictionary<string, string> HelperEnvironment() => new()
    {
        ["DIGUP_MODELS"] = ModelsPath,
        ["DIGUP_BACKEND"] = Backend switch
        {
            Backend.Auto => "auto", Backend.Cpu => "cpu", Backend.Nvidia => "nvidia",
            Backend.Amd => "amd", Backend.OpenVinoNpu => "openvino-npu", _ => throw new ArgumentOutOfRangeException()
        },
        ["DIGUP_OPENVINO_PYTHON"] = OpenVinoPython,
        ["DIGUP_OPENVINO_WORKER"] = OpenVinoWorker,
        ["DIGUP_OPENVINO_MODELS"] = OpenVinoModels,
        ["PYTHONUTF8"] = "1"
    };

    public string[] Arguments(string command)
    {
        List<string> args = [command, "--index", IndexDirectory];
        if (command == "index-service") args.AddRange(["--backfill", "--prune"]);
        foreach (var path in SkippedFolders) args.AddRange(["--exclude", path]);
        foreach (var extension in ExcludedExtensions) args.AddRange(["--exclude-ext", extension]);
        foreach (var path in CodeFolders) args.AddRange(["--code-root", path]);
        foreach (var path in CodeSkippedFolders) args.AddRange(["--code-exclude", path]);
        args.AddRange(Folders);
        return [.. args];
    }
}

public static class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
    public static async Task<Settings> LoadAsync(string path, CancellationToken cancellation = default)
    {
        if (!File.Exists(path)) return new();
        using var file = File.OpenRead(path);
        return await JsonSerializer.DeserializeAsync<Settings>(file, Options, cancellation)
            ?? throw new InvalidDataException("The settings file is empty.");
    }

    public static async Task SaveAsync(Settings settings, string path, CancellationToken cancellation = default)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await JsonSerializer.SerializeAsync(file, settings, Options, cancellation);
                file.Flush(true);
            }
            cancellation.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
