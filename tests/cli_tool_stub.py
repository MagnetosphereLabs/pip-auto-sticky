#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['PIP_TEST_ROOT'])
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')

if name == 'curl':
    source = Path(os.environ['PIP_TEST_SCRIPT'])
    if '-o' in args:
        shutil.copyfile(source, args[args.index('-o') + 1])
    else:
        sys.stdout.write(source.read_text())
elif name == 'mkdir':
    args = [arg for arg in args if arg != str(Path.home() / '.local/bin')]
    if any(not arg.startswith('-') for arg in args):
        os.execv(os.environ['PIP_TEST_MKDIR'], ['mkdir', *args])
elif name == 'ln':
    expected = str(Path.home() / '.local/bin/pip-sticky')
    if args != ['-sfn', str(root / 'user data/pip-sticky/pip-sticky.sh'), expected]:
        raise SystemExit(f'Unexpected symlink arguments: {args}')
    destination = root / 'bin/pip-sticky'
    destination.parent.mkdir(exist_ok=True)
    destination.unlink(missing_ok=True)
    destination.symlink_to(args[1])
elif name == 'systemctl':
    if 'is-enabled' in args or 'is-active' in args:
        raise SystemExit(1)
elif name == 'gsettings':
    if args[0] == 'get':
        print('false' if args[-1] == 'disable-user-extensions' else '[]')
elif name == 'sudo':
    raise SystemExit('Unexpected package installation')
