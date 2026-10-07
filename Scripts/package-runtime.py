#!/usr/bin/env python3
"""Package only our compiled upstream Wine and the user's official Apple redist."""
import pathlib, shutil, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
runtime = root/'Runtime/wine'
subprocess.run(['ditto','/private/tmp/gptk4-runtime11',str(runtime)],check=True)
apple = root/'RuntimeMedia/Extracted/Evaluation environment for Windows games 4.0 beta 1/redist'
subprocess.run(['ditto',str(apple/'lib/external'),str(runtime/'lib/external')],check=True)
subprocess.run(['ditto',str(apple/'lib/wine/x86_64-windows'),str(runtime/'AppleGraphics')],check=True)
subprocess.run(['ditto',str(apple/'lib/wine/x86_64-windows'),str(runtime/'lib/wine/x86_64-windows')],check=True)
# 7-Zip omitted these internal relative symlinks. Restore exactly the DMG targets.
for name in ['d3d10','d3d11','d3d12','dxgi','nvapi64','nvngx-on-metalfx']:
    dst = runtime/'lib/wine/x86_64-unix'/f'{name}.so'
    if dst.exists() or dst.is_symlink(): dst.unlink()
    dst.symlink_to('../../external/libd3dshared.dylib')
if not (runtime/'bin/wine').exists():
    (runtime/'bin/wine').symlink_to('wine64')
# Wine's installation strips Mach-O signatures; sign our built host modules locally.
for p in runtime.rglob('*'):
    if p.is_file() and not p.is_symlink() and 'external' not in p.parts:
        with p.open('rb') as f: magic=f.read(4)
        if magic in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf']:
            subprocess.run(['codesign','--force','--sign','-',str(p)],check=True)
