from pathlib import Path
import subprocess
base=Path('ThirdParty/wine-wine-11.0/dlls/winemac.drv')
backup=Path('ThirdParty/Patches/wine11-original');backup.mkdir(exist_ok=True)
if 'gptk_macdrv_functions' in (base/'macdrv_main.c').read_text():
    raise SystemExit('Wine 11 Apple interface is already applied')
for name in ['macdrv_main.c','dllmain.c','unixlib.h','Makefile.in']:
    (backup/name).write_bytes((base/name).read_bytes())
p=base/'unixlib.h';s=p.read_text().replace('    UINT64 app_quit_request_callback;','    UINT64 app_quit_request_callback;\n    UINT64 gptk_win32[14];',1);p.write_text(s)
funcs=[
('LSTATUS','RegQueryValueExA','HKEY a, LPCSTR b, LPDWORD c, LPDWORD d, BYTE *e, LPDWORD f','a,b,c,d,e,f'),
('LSTATUS','RegSetValueExA','HKEY a, LPCSTR b, DWORD c, DWORD d, const BYTE *e, DWORD f','a,b,c,d,e,f'),
('LSTATUS','RegOpenKeyExA','HKEY a, LPCSTR b, DWORD c, DWORD d, HKEY *e','a,b,c,d,e'),
('LSTATUS','RegCreateKeyExA','HKEY a, LPCSTR b, DWORD c, LPSTR d, DWORD e, DWORD f, LPSECURITY_ATTRIBUTES g, HKEY *h, LPDWORD i','a,b,c,d,e,f,g,h,i'),
('LSTATUS','RegCloseKey','HKEY a','a'),
('BOOL','EnumDisplayMonitors','HDC a, LPRECT b, MONITORENUMPROC c, LPARAM d','a,b,c,d'),
('BOOL','GetMonitorInfoA','HMONITOR a, LPMONITORINFO b','a,b'),
('BOOL','AdjustWindowRectEx','LPRECT a, DWORD b, BOOL c, DWORD d','a,b,c,d'),
('LONG_PTR','GetWindowLongPtrW','HWND a, int b','a,b'),
('BOOL','GetWindowRect','HWND a, LPRECT b','a,b'),
('BOOL','MoveWindow','HWND a, int b, int c, int d, int e, BOOL f','a,b,c,d,e,f'),
('BOOL','SetWindowPos','HWND a, HWND b, int c, int d, int e, int f, UINT g','a,b,c,d,e,f,g'),
('INT','GetSystemMetrics','INT a','a'),
('LONG_PTR','SetWindowLongPtrW','HWND a, INT b, LONG_PTR c','a,b,c')]
p=base/'dllmain.c';s=p.read_text().replace('#include "shellapi.h"','#include "shellapi.h"\n#include "winreg.h"')
n='    params.app_quit_request_callback = (UINT_PTR)macdrv_app_quit_request;'
s=s.replace(n,n+'\n    /* Local Apple LGPL driver-interface adaptation, 2026-10-05. */\n'+''.join(f'    params.gptk_win32[{i}] = (UINT_PTR){f[1]};\n' for i,f in enumerate(funcs)));p.write_text(s)
p=base/'Makefile.in';p.write_text(p.read_text().replace('IMPORTS   = uuid','IMPORTS   = advapi32 uuid'))
p=base/'macdrv_main.c';s=p.read_text().replace('#include "shellapi.h"','#include "shellapi.h"\n#include "winreg.h"')
table=Path('ThirdParty/wine-wine-10.0/dlls/winemac.drv/macdrv_main.c').read_text();table=table[table.index('/* Local adaptation (2026-10-05)'):table.index('/***********************************************************************\n *              macdrv_init\n')]
# Preserve Apple's older four-pointer window-data prefix with a temporary view.
helper='''/* Local LGPL-2.1-or-later adaptation, 2026-10-05.
 * Preserve the published Apple driver table ABI without changing Apple code.
 * Wine 11 has a three-pointer window prefix and switches GSBASE across Unix
 * transitions. Supply a four-pointer compatibility view and GS-aware callbacks.
 */
struct gptk_window_view {
    HWND hwnd;
    macdrv_window window;
    macdrv_view view;
    macdrv_view client_view;
    unsigned char rest[sizeof(struct macdrv_win_data) - 3 * sizeof(void *)];
    struct macdrv_win_data *real;
};
static struct macdrv_win_data *gptk_get_win_data(HWND hwnd)
{
    struct macdrv_win_data *data = get_win_data(hwnd);
    struct gptk_window_view *view;
    if (!data) return NULL;
    if (!(view = malloc(sizeof(*view)))) { release_win_data(data); return NULL; }
    view->hwnd = data->hwnd; view->window = data->cocoa_window;
    view->view = view->client_view = data->client_view;
    memcpy(view->rest, (char *)data + 3 * sizeof(void *), sizeof(view->rest));
    view->real = data;
    return (struct macdrv_win_data *)view;
}
static void gptk_release_win_data(struct macdrv_win_data *arg)
{
    struct gptk_window_view *view = (struct gptk_window_view *)arg;
    release_win_data(view->real); free(view);
}
static UINT64 gptk_callbacks[14];
extern void _thread_set_tsd_base(uint64_t);
'''
for i,(ret,name,decl,args) in enumerate(funcs):
 helper+=f'''static {ret} WINAPI gptk_{name}({decl})
{{
    TEB *teb = NtCurrentTeb();
    void *native_gs = *(void **)((char *)teb + 0x320);
    {ret} result;
    _thread_set_tsd_base((uint64_t)teb);
    result = (({ret} (WINAPI *)({decl}))(UINT_PTR)gptk_callbacks[{i}])({args});
    _thread_set_tsd_base((uint64_t)native_gs);
    return result;
}}
'''
table=table.replace('gptk_init_display_devices, get_win_data, release_win_data,','gptk_init_display_devices, gptk_get_win_data, gptk_release_win_data,').replace('{0}\n};','{'+','.join('(UINT64)gptk_'+f[1] for f in funcs)+'}\n};')
at=s.index('/***********************************************************************\n *              macdrv_init\n');s=s[:at]+helper+table+s[at:]
s=s.replace('    app_icon_callback = params->app_icon_callback;','    memcpy(gptk_callbacks, params->gptk_win32, sizeof(gptk_callbacks));\n    app_icon_callback = params->app_icon_callback;',1).replace('    struct init_params params;','    struct init_params params = {0};')
p.write_text(s)
patch=''
for name in ['macdrv_main.c','dllmain.c','unixlib.h','Makefile.in']:
 r=subprocess.run(['diff','-u','--label','a/dlls/winemac.drv/'+name,'--label','b/dlls/winemac.drv/'+name,str(backup/name),str(base/name)],capture_output=True,text=True);patch+=r.stdout
Path('ThirdParty/Patches/wine11-apple-macdrv-interface.patch').write_text(patch)
