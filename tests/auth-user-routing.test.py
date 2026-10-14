#!/usr/bin/env python3
"""Run only as root in a disposable container: exercises real sudo/runuser/TTY."""
import os
import pathlib
import pty
import select
import shutil
import subprocess
import time

assert os.geteuid() == 0 and pathlib.Path('/.dockerenv').exists(), 'Disposable root Docker container required'
repo = pathlib.Path(__file__).resolve().parents[1]
deployer = 'opsrabbit-auth-fixture'
operator = 'opsrabbit-operator-fixture'
deploy = pathlib.Path('/opt/opsrabbit')
helper = pathlib.Path('/usr/local/bin/opsrabbitctl')
library = pathlib.Path('/usr/local/lib/opsrabbit')
aws = pathlib.Path('/usr/local/bin/aws')
docker = pathlib.Path('/usr/local/bin/docker')
sudoers = pathlib.Path('/etc/sudoers.d/opsrabbit-auth-fixture')
for path in (deploy, helper, library, aws, docker, sudoers):
    assert not path.exists(), f'Refusing to overwrite {path}'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=120, **kwargs)


created_users = []
try:
    for user in (deployer, operator):
        run('useradd', '--create-home', '--shell', '/bin/bash', user)
        created_users.append(user)
    sudoers.write_text(f'{operator} ALL=(root) NOPASSWD: ALL\n')
    sudoers.chmod(0o440)
    run('visudo', '-cf', str(sudoers))
    deploy.mkdir(mode=0o750)
    (deploy / '.env').write_text('''AWS_REGION=us-east-1
ECR_REGISTRY=123456789012.dkr.ecr.us-east-1.amazonaws.com
OPSRABBIT_DAEMON_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/backend:test
OPSRABBIT_WEB_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/web:test
OPSRABBIT_SANDBOX_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox:test
OPSRABBIT_BACKEND_PORT=8384
WEB_HTTP_PORT=3000
OPENSANDBOX_PORT=8080
OPENSANDBOX_SERVER_API_KEY=fixture-key
''')
    (deploy / '.env').chmod(0o600)
    (deploy / 'docker-compose.yml').touch()
    run('chown', '-R', f'{deployer}:{deployer}', str(deploy))
    library.mkdir(parents=True)
    shutil.copyfile(repo / 'bundle/scripts/aws-auth.sh', library / 'aws-auth.sh')
    shutil.copyfile(repo / 'bundle/opsrabbitctl', helper)
    helper.chmod(0o755)
    aws.write_text('''#!/bin/bash
set -euo pipefail
[[ "$(id -un)" == opsrabbit-auth-fixture ]]
[[ "$HOME" == /home/opsrabbit-auth-fixture ]]
[[ "${AWS_EC2_METADATA_DISABLED:-}" == true ]]
[[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${AWS_PROFILE:-}" ]]
[[ "${AWS_CONFIG_FILE:-}" == /dev/null ]]
grep -q 'aws_access_key_id = ASIAFIXTUREONLY' "$AWS_SHARED_CREDENTIALS_FILE"
case "$*" in
  'sts get-caller-identity '*) printf '123456789012\\tarn:aws:iam::123456789012:role/deployer\\n' ;;
  'ecr get-login-password '*) echo fixture-ecr-token ;;
  *) exit 1 ;;
esac
''')
    docker.write_text('''#!/bin/bash
set -euo pipefail
[[ "$(id -un)" == opsrabbit-auth-fixture ]]
[[ "$HOME" == /home/opsrabbit-auth-fixture && "$PWD" == /opt/opsrabbit ]]
case "$*" in
  'login '*) [[ "$(cat)" == fixture-ecr-token ]] ;;
  *' ps -q opensandbox-server') echo fixture-sandbox ;;
  'inspect '*) echo connected ;;
esac
''')
    aws.chmod(0o755)
    docker.chmod(0o755)
    # Real terminal input, entered only once each hidden prompt is active.
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir('/root')  # operator/deployer cannot read this inherited directory
        os.execvp('runuser', ['runuser', '-u', operator, '--', str(helper), 'auth', 'configure'])
    prompts = [
        (b'Select [1]: ', b'2\n'),
        (b'AWS access key ID: ', b'ASIAFIXTUREONLY\n'),
        (b'AWS secret access key: ', b'fixture-secret-hidden\n'),
        (b'Enter for a long-lived key): ', b'fixture-token-hidden\n'),
    ]
    transcript = b''
    pending = b''
    deadline = time.monotonic() + 120
    status = None
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 1)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError:
                data = b''
            transcript += data
            pending += data
            if prompts and prompts[0][0] in pending:
                prompt, answer = prompts.pop(0)
                pending = pending.split(prompt, 1)[1]
                os.write(fd, answer)
        exited, status = os.waitpid(pid, os.WNOHANG)
        if exited:
            break
    else:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        raise AssertionError('Interactive authentication timed out')
    os.close(fd)
    assert status == 0, transcript.decode(errors='replace')
    assert not prompts, 'Not all authentication prompts were reached'
    assert b'fixture-secret-hidden' not in transcript and b'fixture-token-hidden' not in transcript
    assert b'Using sudo to run OpsRabbit as opsrabbit-auth-fixture' in transcript
    state = deploy / '.aws-auth'
    assert state.read_text() == 'credentials\n\n'
    assert state.stat().st_mode & 0o777 == 0o600
    assert state.stat().st_uid == int(run('id', '-u', deployer).stdout.strip())
    credentials = pathlib.Path(f'/home/{deployer}/.aws/opsrabbit/credentials')
    assert credentials.exists() and credentials.stat().st_mode & 0o777 == 0o600
    for args in (['auth', 'status'], ['login'], ['deploy'], ['update']):
        result = run('runuser', '-u', operator, '--', str(helper), *args, cwd='/root')
        assert '123456789012' in result.stdout
    # Root installer entrypoint also uses deployment-owned authentication.
    assert '123456789012' in run(str(helper), 'auth', 'status', cwd='/root').stdout
    print('PASS: real sudo/runuser routing, hidden terminal prompts, deployment HOME, root installer handoff and subsequent reuse')
finally:
    for path in (helper, aws, docker, sudoers):
        path.unlink(missing_ok=True)
    shutil.rmtree(deploy, ignore_errors=True)
    shutil.rmtree(library, ignore_errors=True)
    for user in reversed(created_users):
        run('userdel', '--remove', user)
