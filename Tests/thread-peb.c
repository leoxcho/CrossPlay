/* Local runtime regression test: direct MSVC-style GS:0x60 access on threads. */
#include <windows.h>
static DWORD WINAPI check(void *unused)
{
    void *direct, *expected;
    __asm__ volatile("movq %%gs:0x60,%0" : "=r"(direct));
    expected = *(void **)((char *)NtCurrentTeb() + 0x60);
    return !direct || direct != expected;
}
void mainCRTStartup(void)
{
    HANDLE thread; DWORD result, i;
    if (check(0)) ExitProcess(1);
    for (i = 0; i < 16; i++)
    {
        thread = CreateThread(0,0,check,0,0,0);
        if (!thread) ExitProcess(2);
        WaitForSingleObject(thread,INFINITE);
        if (!GetExitCodeThread(thread,&result) || result) ExitProcess(3);
        CloseHandle(thread);
    }
    ExitProcess(0);
}
