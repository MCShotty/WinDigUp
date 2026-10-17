#include "CGPUAdmission.h"
#include <stdlib.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
struct digup_lease { HANDLE handle; };
digup_lease * digup_lease_try(const char *path, int shared) {
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
    if(count<=0)return NULL;
    wchar_t *wide=(wchar_t *)calloc((size_t)count,sizeof(wchar_t));
    if(!wide)return NULL;
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide,count)){free(wide);return NULL;}
    HANDLE handle=CreateFileW(wide,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
        NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_OPEN_REPARSE_POINT,NULL);
    free(wide);
    if(handle==INVALID_HANDLE_VALUE)return NULL;
    BY_HANDLE_FILE_INFORMATION info;
    if(!GetFileInformationByHandle(handle,&info)||(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)||info.nNumberOfLinks!=1){
        CloseHandle(handle);return NULL;
    }
    OVERLAPPED offset={0};
    if(!LockFileEx(handle,LOCKFILE_FAIL_IMMEDIATELY|(shared?0:LOCKFILE_EXCLUSIVE_LOCK),0,1,0,&offset)){
        CloseHandle(handle);return NULL;
    }
    digup_lease *lease=(digup_lease *)malloc(sizeof(*lease));
    if(!lease){CloseHandle(handle);return NULL;}
    lease->handle=handle;return lease;
}
void digup_lease_release(digup_lease *lease) {
    if(!lease)return;
    OVERLAPPED offset={0};
    UnlockFileEx(lease->handle,0,1,0,&offset);
    CloseHandle(lease->handle);free(lease);
}
double digup_monotonic_seconds(void) {
    LARGE_INTEGER value,frequency;
    QueryPerformanceCounter(&value);QueryPerformanceFrequency(&frequency);
    return (double)value.QuadPart/(double)frequency.QuadPart;
}
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
struct digup_lease { int fd; };
digup_lease * digup_lease_try(const char *path, int shared) {
    int fd=open(path,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600);
    if(fd<0)return NULL;
    struct stat info;
    if(fstat(fd,&info)||!S_ISREG(info.st_mode)||info.st_nlink!=1||info.st_uid!=getuid()){
        close(fd);return NULL;
    }
    if(flock(fd,(shared?LOCK_SH:LOCK_EX)|LOCK_NB)){close(fd);return NULL;}
    digup_lease *lease=(digup_lease *)malloc(sizeof(*lease));
    if(!lease){close(fd);return NULL;}
    lease->fd=fd;return lease;
}
void digup_lease_release(digup_lease *lease) {
    if(!lease)return;
    flock(lease->fd,LOCK_UN);close(lease->fd);free(lease);
}
double digup_monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC,&value);
    return (double)value.tv_sec+(double)value.tv_nsec/1e9;
}
#endif
