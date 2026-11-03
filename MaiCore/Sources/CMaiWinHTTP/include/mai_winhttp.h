#ifndef MAI_WINHTTP_H
#define MAI_WINHTTP_H

#include <stdint.h>

typedef struct MaiWinHTTPRequest MaiWinHTTPRequest;
enum {
  MAI_WINHTTP_SENT = 1,
  MAI_WINHTTP_HEADERS,
  MAI_WINHTTP_AVAILABLE,
  MAI_WINHTTP_READ,
  MAI_WINHTTP_ERROR,
  MAI_WINHTTP_CLOSED
};

// The callback copies read data before returning. CLOSED is the final callback
// and releases the caller's context. All API calls must be serialized by caller.
typedef void (*MaiWinHTTPCallback)(void *context, int event,
  const void *data, uint32_t count, uint32_t error);
MaiWinHTTPRequest *mai_winhttp_create(const char *host, uint16_t port, int secure,
  const char *method, const char *path, const char *headers, int timeout_ms,
  MaiWinHTTPCallback callback, void *context, uint32_t *error);
uint32_t mai_winhttp_send(MaiWinHTTPRequest *, const void *body, uint32_t count);
uint32_t mai_winhttp_receive(MaiWinHTTPRequest *);
uint32_t mai_winhttp_query_available(MaiWinHTTPRequest *);
uint32_t mai_winhttp_read(MaiWinHTTPRequest *, uint32_t count);
// Returns allocated UTF-8 headers, or NULL and a Windows error code.
char *mai_winhttp_headers(MaiWinHTTPRequest *, uint32_t *error);
void mai_winhttp_free(void *);
// Cancels async I/O; destruction is deferred until HANDLE_CLOSING.
// The pointer must never be used again, including from queued callbacks.
void mai_winhttp_close(MaiWinHTTPRequest *);

#endif
