#!/usr/bin/env python3
"""Exercise Nitter's cache against a real, isolated KV 2 cluster."""
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def ready(process, address):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'KV exited: {process.returncode}')
        try:
            connection = http.client.HTTPConnection('127.0.0.1', address, timeout=1)
            connection.request('GET', '/metrics')
            response = connection.getresponse()
            assert response.status == 200
            response.read()
            connection.close()
            return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError('KV startup timed out')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kv', required=True)
    parser.add_argument('--tests', default='tests/test_cache')
    parser.add_argument('--probe', default='tests/cache_probe')
    args = parser.parse_args()
    processes = []
    with tempfile.TemporaryDirectory(prefix='nitter-kv-') as directory:
        root = Path(directory)
        backs, fronts = [port() for _ in range(3)], [port() for _ in range(3)]
        assert len(set(backs + fronts)) == 6
        peers = [{'id': f'back{i}', 'endpoint': f'http://127.0.0.1:{p}'} for i, p in enumerate(backs)]

        def start(role, i):
            address = (backs if role == 'back' else fronts)[i]
            cfg = {'listen': [f'127.0.0.1:{address}']}
            cfg.update({'buckets': {'nitter': 4 * 1024 * 1024}} if role == 'back' else {'peers': peers})
            path = root / f'{role}{i}.json'
            path.write_text(json.dumps(cfg))
            process = subprocess.Popen([args.kv, role, '-c', str(path)], stdout=subprocess.DEVNULL)
            processes.append(process)
            ready(process, address)
            return process

        try:
            for i in range(3):
                start('back', i)
            front_processes = [start('front', i) for i in range(3)]
            endpoints = [f'http://127.0.0.1:{p}' for p in fronts]
            subprocess.run([args.tests], env={**os.environ, 'KV_TEST_ENDPOINTS': ','.join(endpoints)}, check=True)

            def probe(operation, i):
                subprocess.run([args.probe, operation], env={**os.environ, 'KV_TEST_ENDPOINT': endpoints[i]}, check=True)

            probe('write', 0)
            for i in range(3):
                probe('read', i)
            front_processes[0].terminate()
            front_processes[0].wait(timeout=5)
            start('front', 0)
            probe('read', 0)
            print('PASS: three backends, three fronts, separate Nitter processes and front restart')
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
