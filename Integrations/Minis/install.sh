#!/bin/sh
# Run inside Minis with an already transferred, SHA-verified package archive.
# Only the public phone-served client is downloaded. No token or pairing data is read.
set -eu
umask 077
archive=${1:?Pass the local package ZIP path}
archive_sha=${2:?Pass the expected package SHA-256}
ensure_sha='fa9fe8a323d7ed469f55c63ad7340d90c45fcb51b18259c9eaa37c3b65c3b907'
client_sha='ba1941a841755412c4afa3d0932fcec817e46a188e11ff408c5aeb819e6a2b51'
target=/var/minis/skills/ictrl-ready
client_dir="$HOME/.ictrl/bin"
client="$client_dir/ictrl_rpc.py"
runtime="$HOME/.ictrl/runtime"
test -f "$archive"
printf '%s  %s\n' "$archive_sha" "$archive" | sha256sum -c - >/dev/null
test ! -L "$target"
test ! -L "$client"
test ! -L "$runtime"
# Serialize installation with every task start/claim/finish and recheck active
# only after acquiring that same lock. Descriptor 9 survives this exec chain.
if [ "${ICRTL_INSTALL_LOCK_HELD:-0}" != 1 ]; then
python3 -B - "$0" "$archive" "$archive_sha" <<'LOCKPY'
import fcntl, os, pathlib, sys
base = pathlib.Path.home() / '.ictrl/tasks'
base.mkdir(parents=True, exist_ok=True, mode=0o700)
if base.is_symlink(): raise SystemExit('Invalid tasks directory')
os.chmod(base, 0o700)
fd = os.open(base / 'lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
os.dup2(fd, 9, inheritable=True)
if fd != 9: os.close(fd)
fcntl.flock(9, fcntl.LOCK_EX)
env = dict(os.environ)
env['ICRTL_INSTALL_LOCK_HELD'] = '1'
os.execvpe('sh', ['sh', *sys.argv[1:]], env)
LOCKPY
exit $?
fi
python3 -B - "$HOME/.ictrl/tasks/lock" <<'LOCKPY'
import os, sys
actual = os.fstat(9)
expected = os.stat(sys.argv[1], follow_symlinks=False)
if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
    raise SystemExit('Installer lock not inherited')
LOCKPY
# Do not replace a runtime with an active or uncertain task. No task is started here.
python3 -B - "$HOME/.ictrl/tasks" <<'PY'
import json, pathlib, re, sys
base = pathlib.Path(sys.argv[1])
if (base / 'active').exists():
    task = json.loads((base / 'active').read_text(encoding='utf-8'))
    if not isinstance(task, str) or not re.fullmatch(r'[0-9a-f]{32}', task):
        raise SystemExit('Invalid task pointer; no files replaced')
    state = json.loads((base / task / 'state').read_text(encoding='utf-8'))
    if state.get('phase') != 'complete' or state.get('restore') not in {
        'restored', 'already_never', 'user_value_preserved', 'no_record', 'not_required'}:
        raise SystemExit('Previous task not confirmed complete; no files replaced')
PY
mkdir -p "$HOME/.ictrl"
stage=$(mktemp -d "$HOME/.ictrl/ictrl-ready-stage.XXXXXX")
mutation_started=false
committed=false
cleanup_install() {
  code=$?
  trap - EXIT HUP INT TERM
  if [ "$mutation_started" = true ] && [ "$committed" != true ]; then
    if ! rollback; then
      printf '%s\n' 'Installation failed; backup retained, rollback requires inspection.' >&2
    fi
    code=1
  fi
  rm -rf "$stage"
  exit "$code"
}
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
unzip -q "$archive" -d "$stage"
test -f "$stage/ictrl-ready/SKILL.md"
test -f "$stage/ictrl-ready/scripts/ensure-ictrl.sh"
test -f "$stage/ictrl-ready/scripts/quiet_batch.py"
test -f "$stage/ictrl-ready/scripts/automation_session.py"
test -f "$stage/ictrl-ready/scripts/managed_autolock.py"
test -f "$stage/ictrl-ready/scripts/autolock_ui.py"
test -f "$stage/ictrl-ready/scripts/task_context.py"
test -f "$stage/ictrl-ready/scripts/minis_transport.py"
test -f "$stage/ictrl-ready/scripts/task_session.py"
printf '%s  %s\n' "$ensure_sha" "$stage/ictrl-ready/scripts/ensure-ictrl.sh" | sha256sum -c - >/dev/null
curl -q -fsS --noproxy 127.0.0.1 --connect-timeout 2 --max-time 15 \
  'http://127.0.0.1:8200/skill/clients/python' -o "$stage/ictrl_rpc.py"
printf '%s  %s\n' "$client_sha" "$stage/ictrl_rpc.py" | sha256sum -c - >/dev/null
runtime_stage="$stage/runtime"
mkdir -m 700 "$runtime_stage"
for file in ensure-ictrl.sh quiet_batch.py automation_session.py native_session.py managed_autolock.py autolock_ui.py task_context.py minis_transport.py task_session.py; do
  cp "$stage/ictrl-ready/scripts/$file" "$runtime_stage/$file"
done
chmod 700 "$runtime_stage/ensure-ictrl.sh"
chmod 600 "$runtime_stage"/*.py
check_runtime() {
python3 -B - "$1" <<'PY'
import importlib, os, pathlib, sys
scripts = pathlib.Path(sys.argv[1])
expected = {'ensure-ictrl.sh', 'quiet_batch.py', 'automation_session.py', 'native_session.py',
            'managed_autolock.py', 'autolock_ui.py', 'task_context.py', 'minis_transport.py', 'task_session.py'}
assert expected.issubset(set(os.listdir(scripts)))
sys.path.insert(0, str(scripts))
for name in ('automation_session', 'native_session', 'managed_autolock', 'autolock_ui', 'task_context', 'quiet_batch', 'minis_transport', 'task_session'):
    importlib.import_module(name)
print('Quiet runtime listdir and normal imports verified; no batch executed')
PY
}
check_runtime "$runtime_stage"
python3 -B "$runtime_stage/quiet_batch.py" --help >/dev/null
python3 -B "$runtime_stage/task_session.py" --help >/dev/null
# Verify that the local iSH filesystem implements the locks the worker needs.
python3 -B - "$stage" <<'PY'
import fcntl, os, pathlib, sys
path = pathlib.Path(sys.argv[1]) / 'flock-preflight'
a = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
b = os.open(path, os.O_RDWR)
try:
    fcntl.flock(a, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        fcntl.flock(b, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise RuntimeError('Independent lock ownership not enforced')
finally:
    os.close(b)
    os.close(a)
PY
mkdir -p /var/minis/skills "$HOME/.ictrl/backups" "$client_dir"
if [ ! -d "$target" ]; then mkdir "$target"; fi
timestamp=$(date +%Y%m%d-%H%M%S)
backup="$HOME/.ictrl/backups/ictrl-ready-$timestamp"
test ! -e "$backup"
mkdir -m 700 "$backup"
if [ -e "$client" ]; then cp "$client" "$backup/ictrl_rpc.py"; fi
if [ -e "$target/SKILL.md" ]; then cp "$target/SKILL.md" "$backup/SKILL.md"; fi
legacy="$target/scripts/quiet_batch.py"
test ! -L "$legacy"
if [ -f "$legacy" ]; then cp "$legacy" "$backup/legacy-quiet_batch.py"; fi
runtime_installed=false
client_installed=false
skill_installed=false
legacy_installed=false
rollback() {
  failed=false
  if [ "$legacy_installed" = true ]; then
    if [ -f "$backup/legacy-quiet_batch.py" ]; then cp "$backup/legacy-quiet_batch.py" "$legacy" || failed=true
    elif [ -e "$legacy" ]; then mv "$legacy" "$stage/failed-legacy" || failed=true; fi
  fi
  if [ "$skill_installed" = true ]; then
    if [ -f "$backup/SKILL.md" ]; then cp "$backup/SKILL.md" "$target/SKILL.md" || failed=true
    elif [ -e "$target/SKILL.md" ]; then mv "$target/SKILL.md" "$stage/failed-skill" || failed=true; fi
  fi
  if [ "$client_installed" = true ]; then
    if [ -f "$backup/ictrl_rpc.py" ]; then cp "$backup/ictrl_rpc.py" "$client" || failed=true
    elif [ -e "$client" ]; then mv "$client" "$stage/failed-client" || failed=true; fi
  fi
  if [ "$runtime_installed" = true ] && [ -d "$runtime" ]; then mv "$runtime" "$stage/failed-runtime" || failed=true; fi
  if [ -d "$backup/runtime" ]; then mv "$backup/runtime" "$runtime" || failed=true; fi
  [ "$failed" = false ]
}
mutation_started=true
if [ -d "$runtime" ]; then mv "$runtime" "$backup/runtime"; fi
runtime_installed=true
mv "$runtime_stage" "$runtime"
check_runtime "$runtime"
client_installed=true
mv "$stage/ictrl_rpc.py" "$client"
chmod 600 "$client"
skill_temp="$target/.SKILL.md.new-$timestamp"
cp "$stage/ictrl-ready/SKILL.md" "$skill_temp"
skill_installed=true
mv "$skill_temp" "$target/SKILL.md"
# Cached older skills must not retain the old short-lived UI entry point.
mkdir -p "$target/scripts"
cat > "$stage/legacy-quiet_batch.py" <<'PY'
import runpy, sys
from pathlib import Path
runtime = Path.home() / '.ictrl/runtime'
sys.path.insert(0, str(runtime))
if __name__ == '__main__':
    runpy.run_path(str(runtime / 'quiet_batch.py'), run_name='__main__')
else:
    raise ImportError('Import the HOME runtime directly')
PY
cp "$stage/legacy-quiet_batch.py" "$target/scripts/.quiet_batch.py.new-$timestamp"
legacy_installed=true
mv "$target/scripts/.quiet_batch.py.new-$timestamp" "$legacy"
committed=true
# Read-only schema probe; never starts the app or sends an RPC.
if curl -q -fsS --noproxy 127.0.0.1 --connect-timeout 1 --max-time 3 \
    'http://127.0.0.1:8200/schema' -o "$stage/schema.json" && \
   python3 -B - "$stage/schema.json" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding='utf-8'))
    assert value.get('protocol') == 'JSON-RPC 2.0'
    assert any(isinstance(x, dict) and x.get('name') == 'automation_begin' for x in value.get('methods', []))
except (OSError, ValueError, AttributeError, AssertionError):
    sys.exit(1)
PY
then
  printf '%s\n' 'Skill installed; read-only Quiet schema ready. No pairing or task started.'
else
  printf '%s\n' 'Skill installed; read-only schema unavailable. No app start, pairing or quiet batch executed.'
fi
printf 'Previous runtime and skill backup: %s\n' "$backup"
