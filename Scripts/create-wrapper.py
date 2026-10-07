#!/usr/bin/env python3
"""CLI adapter for the same native generator used by CrossPlay's UI."""
import argparse, json, pathlib, subprocess, tempfile
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('executable', type=pathlib.Path)
p.add_argument('destination', type=pathlib.Path)
p.add_argument('--host', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / 'CrossPlay.app')
p.add_argument('--runtime', choices=['Automatic', 'CrossPlay Current', 'GPTK 1.1 Compatibility'], default='Automatic')
p.add_argument('--icon', type=pathlib.Path)
p.add_argument('--prefix', type=pathlib.Path)
p.add_argument('--working-directory', type=pathlib.Path)
p.add_argument('--name')
p.add_argument('--no-avx', action='store_true')
p.add_argument('--arguments', default='[]')
p.add_argument('--environment', default='{}')
a = p.parse_args()
request = dict(executable=str(a.executable.resolve()), runtime=a.runtime, advertiseAVX=not a.no_avx, arguments=json.loads(a.arguments), environment=json.loads(a.environment))
for key, value in [('prefix', a.prefix), ('workingDirectory', a.working_directory), ('icon', a.icon)]:
 if value: request[key] = str(value.resolve())
if a.name: request['gameName'] = a.name
with tempfile.TemporaryDirectory(prefix='crossplay-wrap-') as temporary:
 profile = pathlib.Path(temporary) / 'request.json'; profile.write_text(json.dumps(request))
 subprocess.run([str(a.host.resolve() / 'Contents/MacOS/CrossPlay'), '--create-wrapper-request', str(profile), str(a.destination.resolve())], check=True)
print(a.destination.resolve())
