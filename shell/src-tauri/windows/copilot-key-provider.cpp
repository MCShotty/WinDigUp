#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <string>
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    wchar_t path[32768];DWORD size=GetModuleFileNameW(nullptr,path,32768);
    if(!size||size>=32768)return 2;
    std::wstring root(path,size);auto slash=root.find_last_of(L"\\/");
    if(slash==std::wstring::npos)return 2;root.resize(slash);slash=root.find_last_of(L"\\/");
    if(slash==std::wstring::npos)return 2;root.resize(slash);
    std::wstring executable=root+L"\\DigUp.exe";
    SHELLEXECUTEINFOW info{sizeof(info)};info.fMask=SEE_MASK_NOASYNC|SEE_MASK_FLAG_NO_UI;
    info.lpVerb=L"open";info.lpFile=executable.c_str();info.lpParameters=L"--show-panel";info.lpDirectory=root.c_str();info.nShow=SW_SHOWNORMAL;
    return ShellExecuteExW(&info)?0:3;
}
