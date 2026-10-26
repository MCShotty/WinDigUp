// A real detached Windows GUI process. Only CI's own shortcut launches it.
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <fstream>
#include <filesystem>
#include <string>

static std::string utf8(const std::wstring & value) {
    int size=WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
    std::string result(size,'\0');
    WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),result.data(),size,nullptr,nullptr);
    return result;
}
static std::string quoted(const std::wstring & value) {
    std::string result="\"";
    for (unsigned char c:utf8(value)) {
        if(c=='"'||c=='\\') { result+='\\';result+=c; }
        else if(c<32) {const char * h="0123456789abcdef"; result+="\\u00";result+=h[c>>4];result+=h[c&15];}
        else result+=c;
    }
    return result+'"';
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    int count=0; auto args=CommandLineToArgvW(GetCommandLineW(),&count);
    if(args&&count==5&&std::wstring(args[1])==L"--create-shortcut") {
        // WScript.Shell can save non-ACP arguments/directories through its ANSI link interface. Use Unicode COM.
        HRESULT result=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
        if(FAILED(result)){LocalFree(args);return 2;}
        IShellLinkW* link=nullptr;
        result=CoCreateInstance(__uuidof(ShellLink),nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link));
        if(SUCCEEDED(result)) {
            wchar_t executable[32768];GetModuleFileNameW(nullptr,executable,32768);
            std::wstring parameters=L"--record \""+std::wstring(args[3])+L"\" --token \"spaces \u0627\u0644\u0639\u0631\u0628\u064a\u0629\"";
            result=link->SetPath(executable);
            if(SUCCEEDED(result))result=link->SetArguments(parameters.c_str());
            if(SUCCEEDED(result))result=link->SetWorkingDirectory(args[4]);
            if(SUCCEEDED(result))result=link->SetDescription(L"Disposable application launch integration fixture");
            IPersistFile* persistence=nullptr;
            if(SUCCEEDED(result))result=link->QueryInterface(IID_PPV_ARGS(&persistence));
            if(SUCCEEDED(result))result=persistence->Save(args[2],TRUE);
            if(persistence)persistence->Release();
            link->Release();
        }
        CoUninitialize();LocalFree(args);return FAILED(result)?2:0;
    }
    if(!args||(count!=1&&(count<3||std::wstring(args[1])!=L"--record")))return 2;
    const auto recordPath=count==1?std::filesystem::path(L"launch record.json"):std::filesystem::path(args[2]);
    wchar_t cwd[32768];GetCurrentDirectoryW(32768,cwd);
    std::ofstream out(recordPath,std::ios::binary);
    out<<"{\"pid\":"<<GetCurrentProcessId()<<",\"cwd\":"<<quoted(cwd)<<",\"args\":[";
    for(int i=0;i<count;i++){if(i)out<<',';out<<quoted(args[i]);} out<<"]}";out.close();LocalFree(args);
    auto window=CreateWindowExW(0,L"STATIC",L"DigUp application launch fixture",WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,CW_USEDEFAULT,320,120,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
    ShowWindow(window,SW_SHOWNORMAL);
    SetTimer(window,1,120000,[](HWND,UINT,UINT_PTR,DWORD){PostQuitMessage(0);});
    MSG message;
    while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
    return 0;
}
