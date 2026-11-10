import Foundation

public enum WebXDCBridge {
  public static func script(selfAddr: String, selfName: String, allowFileImport: Bool = false, allowRealtime: Bool = false) -> String {
    """
    (function () {
      if (window.webxdc) { return; }
      var listener = null;
      var pending = [];
      var maxSerial = 0;
      function toUpdate(item) {
        var payload = null;
        try { payload = JSON.parse(item.payloadJSON); } catch (e) {}
        var update = { payload: payload, serial: item.serial, max_serial: maxSerial };
        if (item.info) { update.info = item.info; }
        if (item.document) { update.document = item.document; }
        if (item.summary) { update.summary = item.summary; }
        return update;
      }
      window.__webxdcDeliver = function (items) {
        items.forEach(function (item) {
          if (item.serial > maxSerial) { maxSerial = item.serial; }
        });
        items.forEach(function (item) {
          var update = toUpdate(item);
          if (listener) { listener(update); } else { pending.push(update); }
        });
      };
      function post(message) {
        try { window.webkit.messageHandlers.webxdc.postMessage(message); } catch (e) {}
      }
      window.webxdc = {
        selfAddr: \(jsString(selfAddr)),
        selfName: \(jsString(selfName)),
        sendUpdate: function (update, descr) {
          update = update || {};
          var payload = update.payload === undefined ? null : update.payload;
          var payloadJSON = "null";
          try { payloadJSON = JSON.stringify(payload); } catch (e) {}
          if (payloadJSON === undefined) { payloadJSON = "null"; }
          post({
            type: "sendUpdate",
            payload: payloadJSON,
            info: update.info ? String(update.info) : null,
            document: update.document ? String(update.document) : null,
            summary: update.summary ? String(update.summary) : null
          });
        },
        setUpdateListener: function (callback, serial) {
          listener = callback;
          // Discard anything buffered before the listener existed: the ready
          // handshake makes the host resend every update newer than `serial`,
          // so replaying the buffer here would deliver duplicates.
          pending = [];
          post({ type: "ready", serial: serial || 0 });
          return Promise.resolve();
        },
        sendToChat: function (message) {
          message = message || {};
          var text = message.text ? String(message.text) : "";
          if (message.file && message.file.plainText) {
            text = text ? text + "\\n" + message.file.plainText : message.file.plainText;
          }
          post({ type: "sendToChat", text: text });
          return Promise.resolve();
        },
        importFiles: function (filter) {
          if (!\(allowFileImport ? "true" : "false")) {
            return Promise.resolve([]);
          }
          return Promise.resolve([]);
        },
        joinRealtimeChannel: function () {
          if (!\(allowRealtime ? "true" : "false")) {
            throw new Error("realtime channels are disabled in PocketMai");
          }
          throw new Error("realtime channels are not supported in PocketMai");
        }
      };
    })();
    """
  }

  private static func jsString(_ value: String) -> String {
    let data =
      (try? JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed]))
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }
}

