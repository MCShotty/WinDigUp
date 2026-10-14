using System.Text.Json.Serialization;

namespace WinDigUp.Core;

public sealed record SearchHit
{
    public string Path { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Segment { get; init; } = "";
    [JsonPropertyName("segment_id")] public long SegmentId { get; init; }
    public double? Loc { get; init; }
    public double? Score { get; init; }
    public Dictionary<string, string> Info { get; init; } = [];
    public string? Excerpt { get; init; }
    public string Name => System.IO.Path.GetFileName(Path);
    public string Detail => Kind + (Loc is null ? "" : Kind == "pdf" ? $" · page {Loc:0}" : Kind == "code"
        ? $" · line {Loc:0}" : $" · {TimeSpan.FromSeconds(Loc.Value):m\\:ss}");
}
