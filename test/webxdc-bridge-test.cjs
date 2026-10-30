// Run with: node test/webxdc-bridge-test.cjs. Exercises the actual injected script.
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = readFileSync('PocketMai/Services/WebXDCPocketMai.swift', 'utf8');
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
