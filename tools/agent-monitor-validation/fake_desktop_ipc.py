"""Isolated desktop coordination fixture, with no access to real user sessions."""
import json
import socket
import struct
import sys
from pathlib import Path

path, mode = sys.argv[1:]
methods = []
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
server.settimeout(5)
print('ready', flush=True)


def exact(connection, size):
    data = b''
    while len(data) < size:
        part = connection.recv(size-len(data))
        if not part:
            raise EOFError()
        data += part
    return data


def send(connection, value):
    data = json.dumps(value).encode()
    connection.sendall(struct.pack('<I', len(data)) + data)


questions = [{'id': 'direction', 'question': 'Choose a direction', 'options': [
    {'label': 'A', 'description': 'Lower cost'}, {'label': 'B', 'description': 'More scope'}]}]
turn = 'turn-two' if mode == 'stale-turn' else 'turn-one'
request = {'id': 17, 'method': 'item/tool/requestUserInput', 'params': {
    'threadId': 'existing-thread', 'turnId': turn, 'questions': questions}}
requests = [] if mode == 'already-resolved' else [request]
items = []
steering = mode.startswith('steer-')
if steering:
    requests = []
if mode in ('recorded-pending', 'recorded-conflict'):
    items = [{'type': 'userInputResponse', 'requestId': 17, 'turnId': turn,
              'completed': True, 'answers': {'direction': ['B' if mode == 'recorded-conflict' else 'A']}}]
try:
    connection, _ = server.accept()
    connection.settimeout(5)
    with connection:
        while True:
            size = struct.unpack('<I', exact(connection, 4))[0]
            message = json.loads(exact(connection, size))
            method = message.get('method')
            methods.append(method)
            if message.get('type') == 'broadcast':
                assert method == 'thread-stream-following-changed'
                params = message['params']
                assert params['conversationId'] == 'existing-thread'
                assert message['targetClientIds'] == ['owner']
                if params['following']:
                    flags = ['waitingOnApproval'] if mode == 'steer-approval' else (['waitingOnUserInput'] if requests else [])
                    state = {'id': 'existing-thread', 'title': 'Fixture', 'cwd': '/examples/Fixture', 'threadRuntimeStatus': {
                        'type': 'idle' if mode == 'steer-ended' else 'active', 'activeFlags': flags},
                        'turns': [{'turnId': turn, 'status': 'completed' if mode == 'steer-ended' else 'inProgress', 'items': items}], 'requests': requests}
                    send(connection, {'type': 'broadcast', 'method': 'thread-stream-state-changed',
                         'version': 12 if mode == 'new-version' else 11, 'sourceClientId': 'owner',
                         'params': {'conversationId': 'existing-thread', 'hostId': 'local',
                                    'change': {'type': 'snapshot', 'conversationState': state, 'revision': 1}}})
                continue
            assert message.get('type') == 'request'
            response = {'type': 'response', 'requestId': message['requestId'], 'resultType': 'success',
                        'method': method, 'handledByClientId': 'owner'}
            if method == 'initialize':
                response['result'] = {'clientId': 'companion'}
            elif method == 'thread-owner-discovery':
                assert message['version'] == 1
                response['result'] = {'supportsUntrustedAppInput': True}
            elif method == 'thread-follower-submit-user-input':
                assert message['version'] == 1
                assert message['targetClientId'] == 'owner'
                assert message['params']['requestId'] == 17
                assert message['params']['response'] == {'answers': {'direction': {'answers': ['A']}}}
                requests = []
                if mode == 'disconnect':
                    break
                answers = {'direction': ['B' if mode == 'conflict' else 'A']}
                if mode != 'no-evidence':
                    items = [{'type': 'userInputResponse', 'requestId': 17, 'turnId': turn,
                              'completed': True, 'answers': answers}]
                response['result'] = {'ok': True}
            elif method == 'thread-follower-interrupt-turn':
                assert message['version'] == 4
                assert message['params']['expectedTurnId'] == 'turn-one'
                assert message['params']['mode'] == 'user-stop'
                response['result'] = {'ok': True, 'interruptedTurnId': 'turn-one'}
            elif method == 'thread-follower-steer-turn':
                assert steering and message['version'] == 1
                params = message['params']
                assert message['targetClientId'] == 'owner'
                assert params['conversationId'] == 'existing-thread'
                assert params['input'] == [{'type': 'text', 'text': 'Keep it concise; do not publish', 'text_elements': []}]
                assert params['restoreMessage']['context'] == {'workspaceRoots': ['/examples/Fixture']}
                assert 'permissions' not in params and 'toolOutput' not in params
                if mode == 'steer-reject':
                    response['resultType'] = 'error'
                    response['error'] = 'NoActiveTurn'
                else:
                    if mode == 'steer-retarget':
                        turn = 'turn-two'
                    items = [{'type': 'steeringUserMessage', 'targetTurnId': turn, 'status': 'accepted',
                              'clientUserMessageId': params['clientUserMessageId'], 'input': params['input']}]
                    if mode == 'steer-no-evidence':
                        items = []
                    response['result'] = {'result': {'turnId': turn}}
                    if mode == 'steer-disconnect':
                        break
            else:
                raise AssertionError('Unexpected method: ' + str(method))
            send(connection, response)
except (EOFError, ConnectionResetError, BrokenPipeError):
    pass
finally:
    Path(path + '.methods.json').write_text(json.dumps(methods))
    server.close()
