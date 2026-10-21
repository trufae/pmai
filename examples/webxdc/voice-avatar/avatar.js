'use strict';
const $ = id => document.getElementById(id);
const api = window.webxdc?.pocketmai;
let controller, listening;
const history = [];
function state(text) { document.body.dataset.state = text; $('status').textContent = text; }
function select(id, items, label = x => x.name || x.id) {
  $(id).replaceChildren(...items.map(item => new Option(label(item), item.id)));
}
async function models() {
  $('start').disabled = true;
  try {
    const items = await api.models({provider: $('provider').value});
    select('model', [{id: '', name: 'Provider default'}, ...items.map(id => ({id}))]);
    state('Ready');
    $('start').disabled = !capable;
  } catch (e) { state(e.message); }
}
async function voices() {
  const items = await api.voices({provider: $('speech').value});
  select('voice', items, x => x.name + (x.language ? ` (${x.language})` : ''));
}
let capable = false;
async function init() {
  if (api?.host !== 'pocketmai' || api.version !== 1) {
    state('This avatar needs PocketMai with its webxdc voice extensions.'); return;
  }
  const caps = await api.capabilities();
  $('prompt').value = caps.voicePrompt;
  capable = ['inference', 'transcription', 'synthesis'].every(key => caps.permissions[key]);
  if (!capable) {
    state('Enable Inference, Speech to text and Text to speech in this app’s settings, and Microphone / Audio Playback in WebXDC settings. Then reopen the app.');
    return;
  }
  const providers = (await api.providers()).filter(p => p.available);
  select('provider', providers.filter(p => p.capabilities.includes('inference')));
  select('speech', providers.filter(p => p.capabilities.includes('synthesis')));
  $('provider').onchange = () => models().catch(e => state(e.message));
  $('speech').onchange = () => voices().catch(e => state(e.message));
  await Promise.all([models(), voices()]);
}
$('start').onclick = async () => {
  controller = new AbortController();
  const {signal} = controller;
  $('start').disabled = true; $('stop').disabled = false;
  try {
    while (!signal.aborted) {
      state('Listening'); $('finish').disabled = false;
      listening = api.listen({signal, backend: 'file', language: $('language').value,
        silenceSeconds: 1.25, maxSeconds: 30,
        onUpdate: event => { $('status').textContent = event.text || 'Listening'; }});
      let turn;
      try { turn = await listening; }
      finally { listening = null; $('finish').disabled = true; }
      if (!turn.text.trim()) continue;
      history.push({role: 'user', content: turn.text});
      const user = document.createElement('p'); user.textContent = `You: ${turn.text}`;
      $('transcript').append(user);
      state('Thinking');
      const answer = document.createElement('p'); $('transcript').append(answer);
      const result = await api.complete({signal, mode: 'voice',
        provider: $('provider').value, model: $('model').value || undefined,
        systemPrompt: $('prompt').value, messages: history.slice(-20),
        onUpdate: event => { answer.textContent = `Avatar: ${event.text}`; }});
      answer.textContent = `Avatar: ${result.text}`;
      history.push({role: 'assistant', content: result.text});
      state('Speaking');
      await api.speak({signal, text: result.text, provider: $('speech').value,
        voice: $('voice').value, language: $('language').value});
    }
  } catch (e) { state(e.name === 'AbortError' ? 'Stopped' : e.message); }
  finally {
    if (signal.aborted) state('Stopped');
    $('start').disabled = false; $('stop').disabled = true; $('finish').disabled = true;
  }
};
$('stop').onclick = () => controller?.abort();
$('finish').onclick = () => listening?.finish();
window.addEventListener('pagehide', () => controller?.abort());
init().catch(e => state(e.message));
