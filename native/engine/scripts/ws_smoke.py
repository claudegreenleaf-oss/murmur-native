#!/usr/bin/env python3
"""End-to-end smoke test for MurmurEngine /v1/dictate using only the standard library (CI only)."""
import base64, json, os, socket, struct, subprocess, sys, tempfile, time, wave

PORT = int(os.environ.get("PORT", "18798"))
PHRASE = "Um, let's meet at three, actually four o'clock tomorrow with Alex."


def make_audio():
    d = tempfile.mkdtemp()
    aiff, wav = os.path.join(d, "a.aiff"), os.path.join(d, "a.wav")
    subprocess.check_call(["say", "-o", aiff, PHRASE])
    subprocess.check_call(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav])
    with wave.open(wav) as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1
        return w.readframes(w.getnframes())


def send_frame(sock, opcode, payload):
    mask = os.urandom(4)
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    sock.sendall(head + mask + bytes(b ^ mask[i & 3] for i, b in enumerate(payload)))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        c = sock.recv(n - len(buf))
        if not c:
            raise EOFError
        buf += c
    return buf


def recv_frame(sock):
    b0, b1 = recv_exact(sock, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", recv_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", recv_exact(sock, 8))[0]
    return b0 & 0x0F, recv_exact(sock, n)


def main():
    pcm = make_audio()
    print("audio seconds:", len(pcm) / 32000.0)
    sock = socket.create_connection(("127.0.0.1", PORT), timeout=600)
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall((f"GET /v1/dictate HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\nUpgrade: websocket\r\n"
                  f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(1)
    assert b" 101 " in resp.split(b"\r\n")[0], resp
    init = {"type": "init", "init": {
        "metadata": {"session_id": "s", "request_id": "r", "client_version": "t", "mode": "dictation"},
        "preferences": {"user": {"first_name": "Thomas", "last_name": "G", "email": ""}, "languages": ["en"],
                        "vocabulary": {"dictionary": ["Alex"], "starred": []}, "replacements": {}, "snippets": {},
                        "style": {"general_style": {"personal": "formal", "work": "formal", "email": "formal", "other": "formal"},
                                  "editing_strength": "verbatim", "format": "ai", "email_signature": None}}},
            "context": None}
    send_frame(sock, 1, json.dumps(init).encode())
    for i in range(0, len(pcm), 1280):
        send_frame(sock, 2, pcm[i:i + 1280])
    send_frame(sock, 1, b'{"type":"commit"}')
    t0 = time.time()
    while True:
        op, payload = recv_frame(sock)
        if op == 8:
            print("closed by server")
            break
        if op != 1:
            continue
        msg = json.loads(payload)
        print(msg["type"], json.dumps(msg)[:600])
        if msg["type"] == "result":
            print("RESULT raw:", msg["result"]["raw_text"])
            print("RESULT out:", msg["result"]["output"]["plaintext"], "| status", msg["result"]["status"],
                  "| skip", msg["result"]["format_skip_reason"], "| after commit s", round(time.time() - t0, 2))
            break
        if msg["type"] == "error":
            sys.exit(1)


main()
