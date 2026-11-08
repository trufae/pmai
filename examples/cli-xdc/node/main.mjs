const endpoint = process.env.PMAI_APP_RPC;
const text = process.argv[2] ?? 'Summarize the conversation in one sentence.';

if (endpoint) {
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'chat/prompt', params: {text}}),
  });
  if (!response.ok) throw new Error(`pmai returned HTTP ${response.status}`);
  const {result, error} = await response.json();
  if (error) throw new Error(error.message);
  console.log(result.text);
} else {
  console.log(process.argv[2] ?? 'Hello from Node');
}
