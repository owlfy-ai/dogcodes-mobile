#!/usr/bin/env python3
"""Emulator -> real WebRTC -> isolated PC. No real model/account/project use."""
import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

app = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True, help='Booted iOS simulator UUID or emulator-NNNN')
p.add_argument('--flutter', default='flutter')
p.add_argument('--server', type=Path, default=app.parent / 'dogcodes-server/target/debug/dogcodes-server')
p.add_argument('--desktop', type=Path, default=app.parent / 'DogCodes-remote-control/target/debug/remote-acceptance')
a = p.parse_args()

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='dogcodes-p2p-') as directory, tempfile.TemporaryFile() as log:
    folder = Path(directory)
    pc = folder / 'pc'
    pc.mkdir()
    (pc / '.remote-acceptance').touch()
    public, admin = port(), port()
    origin = f'http://127.0.0.1:{public}'
    env = dict(os.environ, DOGCODES_LISTEN=f'127.0.0.1:{public}',
        DOGCODES_ADMIN_LISTEN=f'127.0.0.1:{admin}', DOGCODES_ADMIN_TOKEN=secrets.token_hex(32),
        DOGCODES_DATABASE_URL=os.environ.get('DOGCODES_TEST_DATABASE_URL', 'postgres://dogcodes:local-development-only@127.0.0.1:55432/dogcodes'),
        DOGCODES_REDIS_URL=os.environ.get('DOGCODES_TEST_REDIS_URL', 'redis://127.0.0.1:56379/'),
        DOGCODES_NAMESPACE='p2p_' + secrets.token_hex(12),
        NO_PROXY='localhost,127.0.0.1,::1', no_proxy='localhost,127.0.0.1,::1')
    processes = []
    guard = threading.Lock()
    invitation_path = '/' + secrets.token_hex(24)
    class Setup(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Don't log the temporary invitation or its retrieval token.
        def do_GET(self):
            if self.path != invitation_path:
                self.send_error(404)
                return
            with guard:
                if not (pc / 'invitation.json').exists():
                    process = subprocess.Popen([str(a.desktop.resolve()), '--remote-acceptance', origin, str(pc)], env=env, stdout=log, stderr=log)
                    processes.append(process)
                    for _ in range(600):
                        if process.poll() is not None:
                            self.send_error(500, 'PC fixture exited')
                            return
                        if (pc / 'invitation.json').exists():
                            break
                        time.sleep(.05)
                    else:
                        self.send_error(500, 'PC fixture timeout')
                        return
                invitation = json.loads((pc / 'invitation.json').read_text())['invitation']['uri']
                data = json.dumps(dict(invitation=invitation, service=origin)).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)
    setup = ThreadingHTTPServer(('127.0.0.1', 0), Setup)
    thread = threading.Thread(target=setup.serve_forever, daemon=True)
    try:
        processes.append(subprocess.Popen([str(a.server.resolve())], env=env, stdout=log, stderr=log))
        thread.start()
        defines = folder / 'defines.json'
        defines.write_text(json.dumps({'DOGCODES_P2P_FIXTURE':f'http://127.0.0.1:{setup.server_port}{invitation_path}'}))
        defines.chmod(0o600)
        subprocess.run([a.flutter, 'test', 'integration_test/p2p_test.dart', '-d', a.device,
            '--dart-define-from-file=' + str(defines)], cwd=app, env=env, check=True, timeout=1500)
    except Exception:
        # Fixture diagnostics may contain invitation material. Retain no raw logs.
        print('Isolated P2P acceptance failed; inspect the Flutter test error above.')
        raise
    finally:
        setup.shutdown()
        setup.server_close()
        for process in reversed(processes):
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
