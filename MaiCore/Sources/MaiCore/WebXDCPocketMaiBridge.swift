/// This namespace is a PocketMai extension, never a webxdc standard API.
public enum WebXDCPocketMaiBridge {
  public static let script = #"""
    (function () {
      if (window.top !== window || location.protocol !== 'xdc:' || !window.webxdc) return;
      const pending = new Map();
      let sequence = 0;
      const prefix = Date.now().toString(36) + Math.random().toString(36).slice(2);
      function post(message) { window.webkit.messageHandlers.pocketmai.postMessage(message); }
      function error(code, message) { const e = new Error(message); e.name = code; return e; }
      window.__pocketmaiReply = function (reply) {
        const request = pending.get(reply.id);
        if (!request) return;
        if (reply.event) {
          if (request.onUpdate) {
            try { request.onUpdate(reply); } catch (e) { console.error(e); }
          }
          return;
        }
        pending.delete(reply.id);
        request.cleanup();
        if (reply.error) request.reject(error(reply.error.code, reply.error.message));
        else request.resolve(reply.result);
      };
      function call(method, options = {}) {
        const { signal, onUpdate, ...values } = options;
        const id = prefix + ':' + (++sequence);
        let abort;
        const promise = new Promise((resolve, reject) => {
          if (signal && signal.aborted) { reject(error('AbortError', 'Request cancelled.')); return; }
          abort = function () {
            const request = pending.get(id);
            if (!request) return;
            pending.delete(id);
            request.cleanup();
            try { post({id, method: 'cancel'}); } catch (_) {}
            reject(error('AbortError', 'Request cancelled.'));
          };
          pending.set(id, {resolve, reject, onUpdate,
            cleanup() { if (signal) signal.removeEventListener('abort', abort); }});
          if (signal) signal.addEventListener('abort', abort, {once: true});
          try { post({id, method, options: JSON.parse(JSON.stringify(values))}); }
          catch (e) { pending.delete(id); if (signal) signal.removeEventListener('abort', abort); reject(e); }
        });
        promise.cancel = () => { if (abort) abort(); };
        if (method === 'listen') promise.finish = () => { if (pending.has(id)) post({id, method: 'finishListening'}); };
        return promise;
      }
      window.addEventListener('pagehide', () => {
        for (const [id, request] of pending) {
          try { post({id, method: 'cancel'}); } catch (_) {}
          request.cleanup(); request.reject(error('AbortError', 'Page closed.'));
        }
        pending.clear();
      });
      window.webxdc.pocketmai = Object.freeze({
        host: 'pocketmai', version: 1,
        capabilities: options => call('capabilities', options),
        requestPermissions: options => call('requestPermissions', options),
        providers: options => call('providers', options),
        models: options => call('models', options),
        voices: options => call('voices', options),
        languages: options => call('languages', options),
        complete: options => call('complete', options),
        listen: options => call('listen', options),
        speak: options => call('speak', options)
      });
    })();
    """#
}
