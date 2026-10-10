#!/usr/bin/env python3
"""Actual Swift ↔ Java processes; pipe transport tests framing only, never radio behavior."""
import json, os, queue, random, struct, subprocess, threading
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JAVA = Path(os.environ.get('JAVA_HOME', ROOT / '.build/android-tools/jdk/Contents/Home')) / 'bin/java'

class Peer:
    def __init__(self, language, role, transport, mask, limit, token):
        command = ([str(ROOT / '.build/interop/swift-peer')] if language == 'Swift' else
                   [str(JAVA), '-cp', '.build/interop/lib/*:.build/interop/classes', 'org.nearbyintercom.core.PeerHarness'])
        self.process = subprocess.Popen(command + [role, str(transport), str(mask), str(limit), token],
                                        cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding='utf-8')
        self.output = queue.Queue()
        self.events = []
        def read():
            for line in self.process.stdout:
                self.output.put(json.loads(line))
            self.output.put({'type': 'eof'})
        threading.Thread(target=read, daemon=True).start()

    def command(self, **command):
        self.process.stdin.write(json.dumps(command) + '\n')
        self.process.stdin.flush()
        out = []
        for _ in range(10000):
            event = self.output.get(timeout=10)
            if event['type'] == 'done':
                return out
            if event['type'] in ('error', 'eof'):
                raise AssertionError(event)
            if event['type'] == 'out':
                out.append(bytes.fromhex(event['value']))
            else:
                self.events.append(event)
        raise AssertionError('Harness output bound')

    def values(self, kind):
        return [e['value'] for e in self.events if e['type'] == kind]

    def stop(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()

def check(swift_role, transport, swift_mask, java_mask, limit):
    token = os.urandom(16).hex()
    a = Peer('Swift', swift_role, transport, swift_mask, limit, token)
    b = Peer('Java', 'responder' if swift_role == 'initiator' else 'initiator', transport, java_mask, limit, token)
    rng = random.Random(9127)
    try:
        def pump(origin, messages):
            work = deque([(origin, messages)])
            for _ in range(1000):
                if not work:
                    return
                sender, messages = work.popleft()
                target = b if sender is a else a
                inputs = messages
                if transport == 2:
                    # Coalesce multiple application frames, then split across lengths and payloads.
                    data = b''.join(messages)
                    inputs = []
                    while data:
                        n = rng.randint(1, 97)
                        inputs.append(data[:n]); data = data[n:]
                responses = []
                for data in inputs:
                    responses += target.command(op='receive', hex=data.hex(), now=2)
                if responses:
                    work.append((target, responses))
            raise AssertionError('Cross-process pump bound')

        initiator = a if swift_role == 'initiator' else b
        pump(initiator, initiator.command(op='start', now=0))
        assert a.values('verification') == b.values('verification') and len(a.values('verification')) == 1
        pump(a, a.command(op='verify', now=1))
        assert not a.values('ready') and not b.values('ready')
        pump(b, b.command(op='verify', now=1))
        assert a.values('ready') == b.values('ready') and len(a.values('ready')) == 1
        profile = bytes.fromhex(a.values('ready')[0])
        assert profile[0] == (1 if swift_mask & java_mask & 1 else 2)
        text_a, text_b = ['Swift → Java', 'π' * 2048], ['Java → Swift', '🙂' * 1024]
        for sender, expected in [(a, text_a), (b, text_b)]:
            out = []
            for text in expected:
                out += sender.command(op='text', text=text, now=3)
            pump(sender, out)
        assert b.values('text') == text_a and a.values('text') == text_b
        assert a.values('ack') == [1, 2] and b.values('ack') == [1, 2]
        rate = struct.unpack('>I', profile[1:5])[0]
        step = rate // 50
        codec_bytes = b'\xF8\xFF\xFE' if profile[0] == 1 else b'\x00\x00' * step
        packets = [struct.pack('>IQBH', 1, 0, 2, step) + codec_bytes,
                   struct.pack('>IQBH', 1, step, 1, 0)]
        for sender, target in [(a, b), (b, a)]:
            for packet in packets:
                pump(sender, sender.command(op='audio', hex=packet.hex(), now=4))
            pump(sender, sender.command(op='audioCancel', stream=1, now=5))
            assert target.values('audio') == [p.hex() for p in packets]
            assert target.values('audioCancel') == [1]
        # This checks encrypted audio format bytes. It does not claim codec decode or playout.
        pump(a, a.command(op='tick', now=5005))
        pump(a, a.command(op='close', now=5006))
        assert len(a.values('closed')) == len(b.values('closed')) == 1
        print(f'PASS Swift {swift_role}, {"GATT" if transport == 1 else "L2CAP framing"}, ATT {limit}, codec {profile[0]}: verified text/ACK/audio-format/close both ways')
    finally:
        a.stop(); b.stop()

for args in [('responder', 1, 3, 3, 20), ('initiator', 1, 3, 2, 185),
             ('responder', 2, 3, 3, 185), ('initiator', 2, 3, 3, 185)]:
    check(*args)
print('4 cross-language sessions passed. Physical Bluetooth and Android app integration remain unverified.')
