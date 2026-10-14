using Microsoft.UI.Xaml;

namespace WinDigUp;

public partial class App : Application
{
    private MainWindow? _window;
    private readonly Mutex _singleInstance = new(false, "Local\\WinDigUp");
    public App() => InitializeComponent();
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        bool owned;
        try { owned = _singleInstance.WaitOne(0); } catch (AbandonedMutexException) { owned = true; }
        if (!owned) { NativeDesktop.ActivateExisting(); Exit(); return; }
        _window = new MainWindow();
        _window.Activate();
    }
}
