using Microsoft.UI.Xaml;

namespace WinDigUp;

public partial class App : Application
{
    private MainWindow? _window;
    private readonly Mutex _singleInstance = new(false, "Local\\WinDigUp");
    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception error) StartupDiagnostics.Report(error);
        };
        UnhandledException += (_, args) => StartupDiagnostics.Report(args.Exception);
        StartupDiagnostics.Write($"Starting {typeof(App).Assembly.GetName().Version} on {Environment.OSVersion}");
        try { InitializeComponent(); }
        catch (Exception error) { StartupDiagnostics.Report(error); throw; }
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        bool owned;
        try { owned = _singleInstance.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
        if (!owned) { NativeDesktop.ActivateExisting(); Exit(); return; }
        try
        {
            StartupDiagnostics.Write("Creating main window");
            _window = new MainWindow();
            _window.Activate();
            StartupDiagnostics.Write("Main window activated");
        }
        catch (Exception error) { StartupDiagnostics.Report(error); Exit(); }
    }
}
