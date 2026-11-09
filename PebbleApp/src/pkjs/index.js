/* The watch UI and dictation run in C. PebbleKit JS relays AppMessage over phone loopback. */
var ChaCha20Poly1305 = require('@stablelib/chacha20poly1305').ChaCha20Poly1305;
var hex = require('@stablelib/hex');
var endpoint = 'http://127.0.0.1:21739/pocketmai/pebble/v1';
var token = localStorage.getItem('token') || '';
if (!/^[0-9a-f]{64}$/.test(token)) token = '';
var pending = localStorage.getItem('turn') || '';
var generation = 0;
var sequence = 0;
var pairingCode = '';

function request(method, params, run, callback) {
  var xhr = new XMLHttpRequest();
  var id = ++sequence;
  var cipher, nonce;
  if (token && method !== 'pair') {
    cipher = new ChaCha20Poly1305(hex.decode(token));
    nonce = new Uint8Array(12);
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) crypto.getRandomValues(nonce);
    else for (var i = 1; i < nonce.length; i++) nonce[i] = Math.floor(Math.random() * 256);
    nonce[0] = 0;
    params.method = method;
    // JavaScriptCore's PebbleKit environment has no TextEncoder.
    var text = unescape(encodeURIComponent(JSON.stringify(params)));
    var bytes = Uint8Array.from(text, function (character) { return character.charCodeAt(0); });
    var data = cipher.seal(nonce, bytes);
    method = 'secure';
    params = {data: hex.encode(nonce, true) + hex.encode(data, true)};
  }
  var timer = setTimeout(function () {
    finish('Keep PocketMai open');
    xhr.abort();
  }, 6500);
  function finish(error, result) {
    if (!timer) return;
    clearTimeout(timer);
    timer = null;
    if (run === generation) callback(error, result);
  }
  xhr.open('POST', endpoint, true);
  xhr.setRequestHeader('Content-Type', 'application/json');
  xhr.onload = function () {
    if (xhr.status !== 200) return finish('Check Pebble permissions');
    var response;
    try { response = JSON.parse(xhr.responseText); }
    catch (_) { return finish('Invalid phone response'); }
    if (!response || response.id !== id || !response.result) {
      return finish(response && response.error ? response.error.message : 'Invalid phone response');
    }
    var result = response.result;
    if (cipher && result.status !== 'unpaired' && result.status !== 'unavailable') {
      try {
        var sealed = hex.decode(result.data);
        if (sealed[0] !== 1) return finish('Invalid phone response');
        var clear = cipher.open(sealed.subarray(0, 12), sealed.subarray(12), nonce);
        if (!clear) return finish('Invalid phone response');
        result = JSON.parse(decodeURIComponent(escape(String.fromCharCode.apply(null, clear))));
      } catch (_) { return finish('Invalid phone response'); }
    }
    finish(null, result);
  };
  xhr.onerror = function () { finish(xhr._notAllowed ? 'Allow Local Network' : 'Keep PocketMai open'); };
  xhr.ontimeout = function () { finish('Keep PocketMai open'); };
  xhr.send(JSON.stringify({jsonrpc: '2.0', id: id, method: method, params: params}));
}

function update(status, fields) {
  var message = fields || {};
  message.Status = status;
  Pebble.sendAppMessage(message);
}

function clearPending() {
  pending = '';
  localStorage.removeItem('turn');
}

function disconnected(result) {
  if (result.status === 'unpaired') {
    pairingCode = '';
    clearPending();
    update('Pair in PocketMai', {Presets: ''});
    return true;
  }
  if (result.status === 'unavailable') {
    update('Enable Pebble on phone');
    return true;
  }
  return false;
}

function fetchMenu(run, attempts) {
  request('menu', {}, run, function (error, result) {
    if (error) return update(error);
    if (disconnected(result)) return;
    if (result.status === 'approval') {
      update(pairingCode ? 'Code ' + pairingCode : 'Confirm code on phone');
      if (attempts > 0) setTimeout(function () {
        if (run === generation) fetchMenu(run, attempts - 1);
      }, 2000);
      return;
    }
    if (result.status !== 'ready') return update('Phone unavailable');
    pairingCode = '';
    var presets = result.presets.map(function (p) {
      return p.id + '\t' + p.name.replace(/[\r\n\t]/g, ' ');
    }).join('\n');
    update(result.busy ? 'Agent is working' : 'Ready', {Presets: presets});
    if (pending) setTimeout(function () {
      if (run === generation) poll(run, 120);
    }, 200);
  });
}

function finishTurn(run, attempts, error, result) {
  if (error) return update(error);
  if (disconnected(result)) return;
  switch (result.status) {
    case 'thinking':
      if (attempts === 120) update('Agent is working');
      if (attempts > 0) setTimeout(function () {
        if (run === generation) poll(run, attempts - 1);
      }, 1500);
      else update('Refresh to check reply');
      return;
    case 'reply':
      var id = pending;
      Pebble.sendAppMessage({Status: 'Ready', Reply: result.text}, function () {
        if (pending === id) clearPending();
      }, function () { update('Refresh to check reply'); });
      return;
    case 'error':
    case 'failure':
      clearPending();
      update('Agent error', {Reply: result.text});
      return;
    default:
      clearPending();
      update(result.status === 'busy' ? 'Agent is working' : 'No reply found');
  }
}

function poll(run, attempts) {
  request('status', {turn: pending}, run, function (error, result) {
    finishTurn(run, attempts, error, result);
  });
}

function turnID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
    var n = Math.floor(Math.random() * 16);
    return (c === 'x' ? n : (n & 3) | 8).toString(16);
  });
}

Pebble.addEventListener('ready', function () { fetchMenu(++generation, 60); });
Pebble.addEventListener('appmessage', function (event) {
  var payload = event.payload;
  var run = ++generation;
  switch (payload.Action) {
    case 'menu': return fetchMenu(run, 60);
    case 'pair':
      return request('pair', {}, run, function (error, result) {
        if (error) return update(error);
        if (result.status === 'alreadyPaired') return fetchMenu(run, 60);
        if (result.status === 'pairingBusy') return update('Restart pairing on phone');
        if (disconnected(result)) return;
        if (result.status !== 'approval' || !/^[0-9a-f]{64}$/.test(result.token)
            || !/^\d{6}$/.test(result.code)) return update('Pair in PocketMai');
        token = result.token;
        pairingCode = result.code;
        localStorage.setItem('token', token);
        update('Code ' + pairingCode);
        setTimeout(function () { if (run === generation) fetchMenu(run, 60); }, 2000);
      });
    case 'new':
      return request('new', {}, run, function (error, result) {
        if (error) return update(error);
        if (disconnected(result)) return;
        if (result.status === 'ready') {
          clearPending();
          update('New chat ready');
        } else update('Agent is working');
      });
    case 'voice':
    case 'preset':
      if (!token) return update('Pair in PocketMai');
      if (pending) {
        update('Checking previous reply');
        return poll(run, 120);
      }
      pending = turnID();
      localStorage.setItem('turn', pending);
      var params = {turn: pending};
      params[payload.Action === 'voice' ? 'text' : 'preset'] = payload.Value;
      return request('turn', params, run, function (error, result) {
        finishTurn(run, 120, error, result);
      });
  }
});
