"""Local fixture only: verifies the observer protocol without touching a real Agent."""
import base64
import hashlib
import json
import socket
import struct
import sys
import time
from pathlib import Path

path, mode = sys.argv[1:]
methods = []
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
server.settimeout(5)
print("ready", flush=True)


def exact(connection, size):
    data = b""
    while len(data) < size:
        part = connection.recv(size - len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def frame(connection, data, opcode=1, final=True):
    if isinstance(data, dict):
        data = json.dumps(data).encode()
    header = bytes([(0x80 if final else 0) | opcode])
    length = len(data)
    if length < 126:
        header += bytes([length])
    elif length < 65536:
        header += bytes([126]) + struct.pack("!H", length)
    else:
        header += bytes([127]) + struct.pack("!Q", length)
    connection.sendall(header + data)


try:
    connection, _ = server.accept()
    connection.settimeout(5)
    with connection:
        header = b""
        while not header.endswith(b"\r\n\r\n"):
            header += exact(connection, 1)
        key = [line.split(b":", 1)[1].strip() for line in header.split(b"\r\n")
               if line.lower().startswith(b"sec-websocket-key:")][0]
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        if mode == "bad-handshake":
            accept = b"invalid"
        connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        while True:
            first, second = exact(connection, 2)
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", exact(connection, 2))[0]
            if length == 127:
                length = struct.unpack("!Q", exact(connection, 8))[0]
            assert second & 128, "Client frames must be masked"
            mask = exact(connection, 4)
            data = exact(connection, length)
            data = bytes(value ^ mask[i % 4] for i, value in enumerate(data))
            if first & 15 == 10:
                continue
            request = json.loads(data)
            methods.append(request.get("method", "RESPONSE_TO_SERVER_REQUEST"))
            method = request.get("method")
            if method == "initialized":
                continue
            if mode == "timeout":
                time.sleep(3)
                break
            if mode == "oversized":
                connection.sendall(bytes([0x81, 127]) + struct.pack("!Q", 2 * 1024 * 1024))
                break
            if method == "initialize":
                result = {}
            elif method == "thread/loaded/list":
                result = {"data": ["existing-thread"], "nextCursor": None}
                # The observer must ignore this; it belongs to the owning client.
                frame(connection, {"id": 700, "method": "item/commandExecution/requestApproval", "params": {}})
                frame(connection, b"ping", opcode=9)
            elif method == "thread/read":
                if mode.startswith("control"):
                    assert request["params"]["includeTurns"] is True
                    flags = ["waitingOnApproval"] if mode == "control-approval" else []
                    result = {"thread": {"id": "existing-thread", "status": {"type": "active", "activeFlags": flags},
                              "turns": [{"id": "new-turn" if mode == "control-stale" else "turn-one", "status": "inProgress", "items": []}]}}
                else:
                    assert request["params"]["includeTurns"] is False
                    result = {"thread": {"id": "existing-thread", "name": "Existing task", "status": {"type": "active", "activeFlags": ["waitingOnUserInput"]}}}
            elif method in ("turn/steer", "turn/interrupt") and mode.startswith("control"):
                assert request["params"]["threadId"] == "existing-thread"
                if method == "turn/steer":
                    assert request["params"]["expectedTurnId"] == "turn-one"
                    assert request["params"]["input"] == [{"type": "text", "text": "Keep it concise"}]
                else:
                    assert request["params"]["turnId"] == "turn-one"
                if mode == "control-disconnect":
                    break
                if mode == "control-reject":
                    frame(connection, {"id": request["id"], "error": {"code": -32000, "message": "Rejected"}})
                    continue
                result = {} if method == "turn/interrupt" else {"turnId": "turn-one"}
            else:
                raise AssertionError("Unexpected mutating method: " + str(method))
            response = json.dumps({"id": request["id"], "result": result}).encode()
            middle = len(response) // 2
            frame(connection, response[:middle], final=False)
            frame(connection, response[middle:], opcode=0)
except (EOFError, BrokenPipeError, ConnectionResetError):
    pass
finally:
    Path(path + ".methods.json").write_text(json.dumps(methods))
    server.close()
