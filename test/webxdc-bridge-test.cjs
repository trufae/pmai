// Run with: node test/webxdc-bridge-test.cjs. Exercises the actual injected script.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('MaiCore/Sources/MaiCore/WebXDCPocketMaiBridge.swift', 'utf8');
const script = source.split('static let script = #"""')[1].split('"""#')[0];
function host() {
  const messages = [], events = {};
  const window = {webxdc: {}, addEventListener: (name, fn) => events[name] = fn,
    webkit: {messageHandlers: {pocketmai: {postMessage: value => messages.push(value)}}}};
  window.top = window;
  vm.runInNewContext(script, {window, location: {protocol: 'xdc:'}, console});
  return {window, api: window.webxdc.pocketmai, messages, events};
}
(async () => {
  // The iOS and Mac hosts use this same standard bridge. Reopening an app
  // must replay updates once, from the serial requested by its listener.
  const standardSource = readFileSync('MaiCore/Sources/MaiCore/WebXDCBridge.swift', 'utf8');
  const standard = standardSource.split('    """')[1]
    .replaceAll('\\(jsString(selfAddr))', '"you@pmai"')
    .replaceAll('\\(jsString(selfName))', '"You"')
    .replaceAll(/\\\(allow(?:FileImport|Realtime) \? "true" : "false"\)/g, 'false')
    .replaceAll('\\\\n', '\\n');
  const posted = [], delivered = [];
  const standardWindow = {webkit: {messageHandlers: {webxdc: {postMessage: m => posted.push(m)}}}};
  vm.runInNewContext(standard, {window: standardWindow});
  standardWindow.__webxdcDeliver([{serial: 1, payloadJSON: '{"move":1}'}]);
  await standardWindow.webxdc.setUpdateListener(update => delivered.push(update), 0);
  assert.equal(delivered.length, 0);
  assert.equal(posted.at(-1).type, 'ready');
  standardWindow.__webxdcDeliver([{serial: 1, payloadJSON: '{"move":1}'}]);
  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].payload.move, 1);
  standardWindow.webxdc.sendUpdate({payload: {move: 2}});
  assert.equal(posted.at(-1).payload, '{"move":2}');
  await standardWindow.webxdc.sendToChat({text: 'Score', file: {plainText: '42'}});
  assert.equal(posted.at(-1).text, 'Score\n42');
  const {api, window, messages, events} = host();
  assert.equal(api.version, 1);
  let snapshots = [];
  const request = api.complete({messages: [{role: 'user', content: 'Hello'}],
    scope: 'chat', systemPrompt: 'Short answers', onUpdate: e => snapshots.push(e.text)});
  const id = messages[0].id;
  assert.equal(messages[0].options.systemPrompt, 'Short answers');
  assert.equal(messages[0].options.scope, 'chat');
  assert.equal(messages[0].options.onUpdate, undefined);
  window.__pocketmaiReply({id, event: 'text', text: 'Hi'});
  window.__pocketmaiReply({id, result: {text: 'Hi!'}});
  assert.equal((await request).text, 'Hi!');
  assert.deepEqual(snapshots, ['Hi']);
  const controller = new AbortController();
  const cancelled = api.listen({signal: controller.signal});
  cancelled.finish();
  assert.equal(messages.at(-1).method, 'finishListening');
  controller.abort();
  await assert.rejects(cancelled, {name: 'AbortError'});
  assert.equal(messages.at(-1).method, 'cancel');
  const count = messages.length;
  await assert.rejects(api.speak({signal: controller.signal}), {name: 'AbortError'});
  assert.equal(messages.length, count);
  const explicit = api.speak({text: 'Hi'});
  explicit.cancel();
  await assert.rejects(explicit, {name: 'AbortError'});
  const denied = api.models();
  window.__pocketmaiReply({id: messages.at(-1).id,
    error: {code: 'NotAllowedError', message: 'Disabled'}});
  await assert.rejects(denied, {name: 'NotAllowedError'});
  const closing = api.capabilities();
  events.pagehide();
  await assert.rejects(closing, {name: 'AbortError'});
  const permissions = api.requestPermissions({capabilities: ['inference', 'synthesis']});
  assert.equal(messages.at(-1).method, 'requestPermissions');
  assert.equal(JSON.stringify(messages.at(-1).options.capabilities), '["inference","synthesis"]');
  window.__pocketmaiReply({id: messages.at(-1).id, result: {permissions: {inference: true}}});
  assert.equal((await permissions).permissions.inference, true);
  console.log('webxdc bridge: streaming, discovery, errors, finish, abort, cancel and page cleanup passed');
})().catch(error => { console.error(error); process.exitCode = 1; });
