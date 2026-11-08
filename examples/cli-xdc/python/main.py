import json
import os
import sys
from urllib.request import Request, urlopen


endpoint = os.environ.get('PMAI_APP_RPC')
if endpoint:
    text = sys.argv[1] if len(sys.argv) > 1 else 'Summarize the conversation in one sentence.'
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'chat/prompt', 'params': {'text': text}})
    request = Request(endpoint, data=body.encode(), headers={'Content-Type': 'application/json'})
    with urlopen(request) as response:
        message = json.load(response)
    if 'error' in message:
        raise SystemExit(message['error']['message'])
    print(message['result']['text'])
else:
    print(sys.argv[1] if len(sys.argv) > 1 else 'Hello from Python')
