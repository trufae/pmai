#include "mai_winhttp.h"
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>

struct MaiWinHTTPRequest {
  HINTERNET session, connection, request;
  MaiWinHTTPCallback callback;
  void *context;
  void *body;
  char buffer[32768];
};

static void destroy(MaiWinHTTPRequest *value) {
  if (value->connection) WinHttpCloseHandle(value->connection);
  if (value->session) WinHttpCloseHandle(value->session);
  free(value->body);
  free(value);
}

static void CALLBACK status_callback(HINTERNET handle, DWORD_PTR context,
    DWORD status, void *information, DWORD length) {
  (void)handle;
  MaiWinHTTPRequest *value = (MaiWinHTTPRequest *)context;
  if (!value) return;
  int event;
  uint32_t count = 0, error = 0;
  const void *data = NULL;
  switch (status) {
  case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE: event = MAI_WINHTTP_SENT; break;
  case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE: event = MAI_WINHTTP_HEADERS; break;
  case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
    event = MAI_WINHTTP_AVAILABLE;
    count = *(DWORD *)information;
    break;
  case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
    event = MAI_WINHTTP_READ;
    data = information;
    count = length;
    break;
  case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
    event = MAI_WINHTTP_ERROR;
    error = ((WINHTTP_ASYNC_RESULT *)information)->dwError;
    break;
  case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING: {
    // Only the request has a callback. Its final notification means the body
    // and read buffer are no longer in use, including after cancellation.
    MaiWinHTTPCallback callback = value->callback;
    void *user_context = value->context;
    destroy(value);
    callback(user_context, MAI_WINHTTP_CLOSED, NULL, 0, 0);
    return;
  }
  default: return;
  }
  value->callback(value->context, event, data, count, error);
}

static WCHAR *wide(const char *text) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
  if (!count) return NULL;
  WCHAR *result = malloc((size_t)count * sizeof(WCHAR));
  if (!result) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result, count)) {
    DWORD error = GetLastError();
    free(result);
    SetLastError(error);
    return NULL;
  }
  return result;
}

MaiWinHTTPRequest *mai_winhttp_create(const char *host, uint16_t port, int secure,
    const char *method, const char *path, const char *headers, int timeout_ms,
    MaiWinHTTPCallback callback, void *context, uint32_t *error) {
  MaiWinHTTPRequest *value = calloc(1, sizeof(*value));
  WCHAR *w_host = NULL, *w_method = NULL, *w_path = NULL, *w_headers = NULL;
  *error = ERROR_NOT_ENOUGH_MEMORY;
  if (!value) return NULL;
  value->callback = callback;
  value->context = context;
  if (!(w_host = wide(host)) || !(w_method = wide(method)) ||
      !(w_path = wide(path)) || !(w_headers = wide(headers))) goto fail;
  value->session = WinHttpOpen(L"pmai", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
  if (!value->session) goto fail;
  if (!WinHttpSetTimeouts(value->session, timeout_ms,
      timeout_ms < 30000 ? timeout_ms : 30000, timeout_ms, timeout_ms)) goto fail;
  value->connection = WinHttpConnect(value->session, w_host, port, 0);
  if (!value->connection) goto fail;
  value->request = WinHttpOpenRequest(value->connection, w_method, w_path, NULL,
    WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
  if (!value->request) goto fail;
  // Swift applies the same-origin policy. Never send Windows login credentials
  // automatically or share cookies between provider requests.
  DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
  DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_GZIP | WINHTTP_DECOMPRESSION_FLAG_DEFLATE;
  DWORD_PTR native_context = (DWORD_PTR)value;
  if (!WinHttpSetOption(value->request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)) ||
      !WinHttpSetOption(value->request, WINHTTP_OPTION_DECOMPRESSION, &decompression, sizeof(decompression)) ||
      !WinHttpSetOption(value->request, WINHTTP_OPTION_CONTEXT_VALUE, &native_context, sizeof(native_context))) goto fail;
  if (*headers && !WinHttpAddRequestHeaders(value->request, w_headers, (DWORD)-1L,
      WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE)) goto fail;
  // Install last: setup failures have no callbacks and can be freed immediately.
  if (WinHttpSetStatusCallback(value->request, status_callback,
      WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0)
      == WINHTTP_INVALID_STATUS_CALLBACK) goto fail;
  free(w_host); free(w_method); free(w_path); free(w_headers);
  *error = 0;
  return value;
fail:
  *error = GetLastError();
  free(w_host); free(w_method); free(w_path); free(w_headers);
  if (value->request) WinHttpCloseHandle(value->request);
  destroy(value);
  return NULL;
}

uint32_t mai_winhttp_send(MaiWinHTTPRequest *value, const void *body, uint32_t count) {
  if (count) {
    value->body = malloc(count);
    if (!value->body) return ERROR_NOT_ENOUGH_MEMORY;
    memcpy(value->body, body, count);
  }
  return WinHttpSendRequest(value->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
    value->body, count, count, (DWORD_PTR)value) ? 0 : GetLastError();
}

uint32_t mai_winhttp_receive(MaiWinHTTPRequest *value) {
  return WinHttpReceiveResponse(value->request, NULL) ? 0 : GetLastError();
}

uint32_t mai_winhttp_query_available(MaiWinHTTPRequest *value) {
  return WinHttpQueryDataAvailable(value->request, NULL) ? 0 : GetLastError();
}

uint32_t mai_winhttp_read(MaiWinHTTPRequest *value, uint32_t count) {
  if (!count || count > sizeof(value->buffer)) return ERROR_INVALID_PARAMETER;
  return WinHttpReadData(value->request, value->buffer, count, NULL) ? 0 : GetLastError();
}

char *mai_winhttp_headers(MaiWinHTTPRequest *value, uint32_t *error) {
  DWORD bytes = 0;
  *error = 0;
  WinHttpQueryHeaders(value->request, WINHTTP_QUERY_RAW_HEADERS_CRLF,
    WINHTTP_HEADER_NAME_BY_INDEX, NULL, &bytes, WINHTTP_NO_HEADER_INDEX);
  *error = GetLastError();
  if (*error != ERROR_INSUFFICIENT_BUFFER) return NULL;
  if (bytes > 131072) { *error = ERROR_WINHTTP_HEADER_SIZE_OVERFLOW; return NULL; }
  WCHAR *buffer = malloc(bytes);
  if (!buffer) { *error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
  char *result = NULL;
  if (!WinHttpQueryHeaders(value->request, WINHTTP_QUERY_RAW_HEADERS_CRLF,
      WINHTTP_HEADER_NAME_BY_INDEX, buffer, &bytes, WINHTTP_NO_HEADER_INDEX)) goto fail;
  int count = WideCharToMultiByte(CP_UTF8, 0, buffer, -1, NULL, 0, NULL, NULL);
  if (!count) goto fail;
  result = malloc((size_t)count);
  if (!result) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); goto fail; }
  if (!WideCharToMultiByte(CP_UTF8, 0, buffer, -1, result, count, NULL, NULL)) {
    free(result);
    result = NULL;
    goto fail;
  }
  free(buffer);
  *error = 0;
  return result;
fail:
  *error = GetLastError();
  free(buffer);
  return NULL;
}

void mai_winhttp_close(MaiWinHTTPRequest *value) {
  WinHttpCloseHandle(value->request);
}

#else
// Keep the Swift adapter type-checked on every platform, without Windows SDK
// headers or libraries. Explicit selection elsewhere reports unsupported URL.
MaiWinHTTPRequest *mai_winhttp_create(const char *host, uint16_t port, int secure,
    const char *method, const char *path, const char *headers, int timeout_ms,
    MaiWinHTTPCallback callback, void *context, uint32_t *error) {
  (void)host; (void)port; (void)secure; (void)method; (void)path;
  (void)headers; (void)timeout_ms; (void)callback; (void)context;
  *error = 50; // ERROR_NOT_SUPPORTED
  return NULL;
}
uint32_t mai_winhttp_send(MaiWinHTTPRequest *value, const void *body, uint32_t count) {
  (void)value; (void)body; (void)count; return 50;
}
uint32_t mai_winhttp_receive(MaiWinHTTPRequest *value) { (void)value; return 50; }
uint32_t mai_winhttp_query_available(MaiWinHTTPRequest *value) { (void)value; return 50; }
uint32_t mai_winhttp_read(MaiWinHTTPRequest *value, uint32_t count) { (void)value; (void)count; return 50; }
char *mai_winhttp_headers(MaiWinHTTPRequest *value, uint32_t *error) { (void)value; *error = 50; return NULL; }
void mai_winhttp_close(MaiWinHTTPRequest *value) { (void)value; }
#endif

void mai_winhttp_free(void *value) { free(value); }
