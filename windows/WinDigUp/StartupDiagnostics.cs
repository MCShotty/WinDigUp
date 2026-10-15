using System.Runtime.InteropServices;
using WinDigUp.Core;

namespace WinDigUp;

internal static class StartupDiagnostics
{
    private static int _reported;
    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(Settings.DataDirectory);
            File.AppendAllText(Path.Combine(Settings.DataDirectory, "startup.log"),
                $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch { /* Diagnostics must not prevent startup or obscure the original exception. */ }
    }

    public static void Report(Exception error)
    {
        Write($"HRESULT 0x{error.HResult:X8}: {error}");
        foreach (System.Collections.DictionaryEntry detail in error.Data)
            Write($"{detail.Key}: {detail.Value}");
        if (Interlocked.Exchange(ref _reported, 1) != 0) return;
        MessageBox(0, $"WinDigUp could not start.\n\n{error.Message}\n\nDetails: {Path.Combine(Settings.DataDirectory, "startup.log")}",
            "WinDigUp startup error", 0x10);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
    private static extern int MessageBox(nint window, string text, string caption, uint type);
}
