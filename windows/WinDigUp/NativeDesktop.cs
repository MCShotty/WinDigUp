using System.Runtime.InteropServices;

namespace WinDigUp;

/// The tray and global shortcut share the WinUI window's message loop; no second UI framework is needed.
internal sealed class NativeDesktop : IDisposable
{
    private const uint TrayMessage = 0x8029, ShowMessage = 0x802A;
    private readonly nint _window;
    private readonly SubclassProc _callback;
    private readonly Action<string> _action;
    private readonly uint _taskbarCreated;
    private NotifyIcon _icon;
    public bool HotkeyRegistered { get; }

    public NativeDesktop(nint window, Action<string> action)
    {
        _window = window; _action = action; _callback = WindowProc;
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        if (!SetWindowSubclass(window, _callback, 1, 0)) throw new InvalidOperationException("Could not attach the window message handler.");
        HotkeyRegistered = RegisterHotKey(window, 1, 0x4006, 0x20); // Ctrl+Shift+Space, no key repeats
        _icon = new NotifyIcon
        {
            Size = (uint)Marshal.SizeOf<NotifyIcon>(), Window = window, Id = 1, Flags = 7,
            CallbackMessage = TrayMessage, Icon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "icon.ico"), 1, 16, 16, 0x10),
            Tip = "WinDigUp · Ctrl+Shift+Space", Info = "", InfoTitle = ""
        };
        ShellNotifyIcon(0, ref _icon);
    }

    private nint WindowProc(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        if (message == 0x0312 || message == ShowMessage) _action("show");
        if (message == _taskbarCreated) ShellNotifyIcon(0, ref _icon);
        if (message == TrayMessage)
        {
            if ((uint)lParam is 0x0202 or 0x0203) _action("show");
            if ((uint)lParam == 0x0205)
            {
                var menu = CreatePopupMenu();
                try
                {
                    AppendMenu(menu, 0, 1, "Search"); AppendMenu(menu, 0, 2, "Folders and settings");
                    AppendMenu(menu, 0, 3, "Pause / resume indexing"); AppendMenu(menu, 0, 4, "Quit WinDigUp");
                    GetCursorPos(out var point); SetForegroundWindow(window);
                    var command = TrackPopupMenu(menu, 0x0102, point.X, point.Y, 0, window, 0);
                    if (command != 0) _action(command switch { 1 => "show", 2 => "settings", 3 => "pause", _ => "quit" });
                }
                finally { DestroyMenu(menu); }
            }
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }

    public void Show() { ShowWindow(_window, 9); SetForegroundWindow(_window); }
    public void Hide() => ShowWindow(_window, 0);
    public static void ActivateExisting()
    {
        var window = FindWindow(null, "WinDigUp");
        if (window != 0) PostMessage(window, ShowMessage, 0, 0);
    }

    public void Dispose()
    {
        UnregisterHotKey(_window, 1); ShellNotifyIcon(2, ref _icon);
        RemoveWindowSubclass(_window, _callback, 1);
        if (_icon.Icon != 0) DestroyIcon(_icon.Icon);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyIcon
    {
        public uint Size; public nint Window; public uint Id, Flags, CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowSubclass(nint window, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RemoveWindowSubclass(nint window, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShowWindow(nint window, int show);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint FindWindow(string? className, string name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessage(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint LoadImage(nint instance, string name, uint type, int x, int y, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(nint icon);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool ShellNotifyIcon(uint message, ref NotifyIcon icon);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rectangle);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetCursorPos(out Point point);
}
