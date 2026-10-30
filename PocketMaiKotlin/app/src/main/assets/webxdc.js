(function () {
  if (window.top !== window || window.webxdc) return;
  let listener = null;
  let maxSerial = 0;
  const post = body => window.PocketMaiHost.postMessage(JSON.stringify(body));
  window.__webxdcDeliver = function (items) {
    for (const item of items) maxSerial = Math.max(maxSerial, item.serial);
    if (!listener) return;
    for (const item of items) {
      const update = {payload: JSON.parse(item.payloadJSON), serial: item.serial, max_serial: maxSerial};
      for (const key of ['info', 'document', 'summary']) if (item[key]) update[key] = item[key];
      listener(update);
    }
  };
  window.webxdc = {
    selfAddr: 'you@pocketmai', selfName: 'You',
    sendUpdate(update = {}, description = '') {
      post({type: 'sendUpdate', payload: JSON.stringify(update.payload ?? null),
        info: update.info, document: update.document, summary: update.summary});
    },
    setUpdateListener(callback, serial = 0) {
      listener = callback;
      post({type: 'ready', serial});
      return Promise.resolve();
    },
    sendToChat(message = {}) {
      post({type: 'sendToChat', text: [message.text, message.file?.plainText].filter(Boolean).join('\n')});
      return Promise.resolve();
    },
    importFiles() { return Promise.resolve([]); },
    joinRealtimeChannel() { throw new Error('Realtime channels are not supported by this host.'); }
  };
})();
