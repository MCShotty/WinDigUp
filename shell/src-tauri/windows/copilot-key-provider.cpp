#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <objbase.h>
#include <string>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(com)) return 3;
    struct Apartment { ~Apartment() { CoUninitialize(); } } apartment;
    wchar_t path[32768];
    DWORD size = GetModuleFileNameW(nullptr, path, 32768);
    if (!size || size >= 32768) return 2;
    std::wstring root(path, size);
    auto slash = root.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return 2;
    root.resize(slash);
    slash = root.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return 2;
    root.resize(slash);
    std::wstring executable = root + L"\\DigUp.exe";
    SHELLEXECUTEINFOW info{sizeof(info)};
    info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI | SEE_MASK_NOCLOSEPROCESS;
    info.lpVerb = L"open";
    info.lpFile = executable.c_str();
    info.lpParameters = L"--show-panel";
    info.lpDirectory = root.c_str();
    info.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&info)) return 3;
    if (info.hProcess) {
        // Forward the user's activation permission while the provider still owns it.
        AllowSetForegroundWindow(GetProcessId(info.hProcess));
        WaitForInputIdle(info.hProcess, 5000);
        CloseHandle(info.hProcess);
    }
    return 0;
}
