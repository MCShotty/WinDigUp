#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <wchar.h>
#include "CGPUAdmission.h"
static char *utf8(const wchar_t *text){
    int size=WideCharToMultiByte(CP_UTF8,0,text,-1,NULL,0,NULL,NULL);
    char *out=(char *)calloc((size_t)size,1);
    assert(out&&WideCharToMultiByte(CP_UTF8,0,text,-1,out,size,NULL,NULL));
    return out;
}
int wmain(int argc,wchar_t **argv){
    if(argc==3&&!wcscmp(argv[1],L"--hold")){
        char *path=utf8(argv[2]);digup_lease *lease=digup_lease_try(path,0);
        assert(lease);puts("ready");fflush(stdout);Sleep(60000);digup_lease_release(lease);free(path);return 0;
    }
    wchar_t temp[MAX_PATH],root[MAX_PATH],file[MAX_PATH],exe[MAX_PATH],command[3*MAX_PATH];
    assert(GetTempPathW(MAX_PATH,temp));
    swprintf(root,MAX_PATH,L"%lsDigUp admission %lu",temp,GetCurrentProcessId());
    assert(CreateDirectoryW(root,NULL));
    swprintf(file,MAX_PATH,L"%ls\\space Unicode \x5377.lock",root);
    char *path=utf8(file);
    digup_lease *first=digup_lease_try(path,0);assert(first);
    assert(!digup_lease_try(path,0));digup_lease_release(first);
    first=digup_lease_try(path,1);assert(first);
    digup_lease *second=digup_lease_try(path,1);assert(second);
    assert(!digup_lease_try(path,0));digup_lease_release(second);digup_lease_release(first);
    HANDLE read_pipe,write_pipe;
    SECURITY_ATTRIBUTES security={sizeof(security),NULL,TRUE};
    assert(CreatePipe(&read_pipe,&write_pipe,&security,0));
    assert(SetHandleInformation(read_pipe,HANDLE_FLAG_INHERIT,0));
    STARTUPINFOW startup={0};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;
    startup.hStdOutput=write_pipe;startup.hStdError=write_pipe;startup.hStdInput=GetStdHandle(STD_INPUT_HANDLE);
    assert(GetModuleFileNameW(NULL,exe,MAX_PATH));
    swprintf(command,3*MAX_PATH,L"\"%ls\" --hold \"%ls\"",exe,file);
    PROCESS_INFORMATION process={0};
    assert(CreateProcessW(exe,command,NULL,NULL,TRUE,0,NULL,NULL,&startup,&process));
    CloseHandle(write_pipe);CloseHandle(process.hThread);
    char reply[32]={0};DWORD read=0;assert(ReadFile(read_pipe,reply,31,&read,NULL)&&read>=5);
    assert(!memcmp(reply,"ready",5));assert(!digup_lease_try(path,0));
    assert(TerminateProcess(process.hProcess,1));assert(WaitForSingleObject(process.hProcess,5000)==WAIT_OBJECT_0);
    CloseHandle(process.hProcess);CloseHandle(read_pipe);
    first=digup_lease_try(path,0);assert(first);digup_lease_release(first);
    free(path);DeleteFileW(file);RemoveDirectoryW(root);
    puts("PASS: Windows exclusive/shared admission, spaces/Unicode and automatic release after process termination.");
    return 0;
}
