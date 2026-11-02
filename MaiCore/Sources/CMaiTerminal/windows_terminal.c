#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>
#include "mai_terminal.h"

typedef HRESULT (WINAPI *CreatePTY)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef HRESULT (WINAPI *ResizePTY)(HPCON, COORD);
typedef void (WINAPI *ClosePTY)(HPCON);

struct MaiWindowsPTY {
  HANDLE input, output, process, job, writer;
  HPCON console;
  ResizePTY resize;
  ClosePTY close;
  SRWLOCK lock;
};

static int functions(CreatePTY *create, ResizePTY *resize, ClosePTY *close) {
  HMODULE module = GetModuleHandleW(L"kernel32.dll");
  union { FARPROC raw; CreatePTY typed; } a;
  union { FARPROC raw; ResizePTY typed; } b;
  union { FARPROC raw; ClosePTY typed; } c;
  a.raw = GetProcAddress(module, "CreatePseudoConsole");
  b.raw = GetProcAddress(module, "ResizePseudoConsole");
  c.raw = GetProcAddress(module, "ClosePseudoConsole");
  *create = a.typed; *resize = b.typed; *close = c.typed;
  return *create && *resize && *close;
}

int mai_windows_pty_available(void) {
  CreatePTY create; ResizePTY resize; ClosePTY close;
  return functions(&create, &resize, &close);
}

MaiWindowsPTY *mai_windows_pty_create(const uint16_t *executable, const uint16_t *command,
    const uint16_t *cwd, int columns, int rows, uint32_t *error) {
  CreatePTY create; ResizePTY resize; ClosePTY close;
  if (!functions(&create, &resize, &close)) { *error = ERROR_NOT_SUPPORTED; return NULL; }
  MaiWindowsPTY *pty = calloc(1, sizeof(*pty));
  if (!pty) { *error = ERROR_NOT_ENOUGH_MEMORY; return NULL; }
  InitializeSRWLock(&pty->lock);
  pty->resize = resize; pty->close = close;
  HANDLE input_read = NULL, output_write = NULL;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  PROCESS_INFORMATION child = {0};
  wchar_t *arguments = NULL;
  DWORD failure = ERROR_SUCCESS;
  pty->job = CreateJobObjectW(NULL, NULL);
  if (!pty->job) { failure = GetLastError(); goto fail; }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(pty->job, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) ||
      !CreatePipe(&input_read, &pty->input, NULL, 0) ||
      !CreatePipe(&pty->output, &output_write, NULL, 0)) {
    failure = GetLastError(); goto fail;
  }
  COORD size = {(SHORT)columns, (SHORT)rows};
  HRESULT result = create(size, input_read, output_write, 0, &pty->console);
  if (FAILED(result)) { failure = (DWORD)result; goto fail; }
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
  attributes = HeapAlloc(GetProcessHeap(), 0, bytes);
  if (!attributes) { failure = ERROR_NOT_ENOUGH_MEMORY; goto fail; }
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &bytes)) {
    failure = GetLastError(); HeapFree(GetProcessHeap(), 0, attributes); attributes = NULL; goto fail;
  }
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
      pty->console, sizeof(HPCON), NULL, NULL)) { failure = GetLastError(); goto fail; }
  arguments = _wcsdup((const wchar_t *)command);
  if (!arguments) { failure = ERROR_NOT_ENOUGH_MEMORY; goto fail; }
  STARTUPINFOEXW startup = {0};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes;
  if (!CreateProcessW((LPCWSTR)executable, arguments, NULL, NULL, FALSE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED, NULL, (LPCWSTR)cwd,
      &startup.StartupInfo, &child)) { failure = GetLastError(); goto fail; }
  pty->process = child.hProcess;
  if (!AssignProcessToJobObject(pty->job, child.hProcess) || ResumeThread(child.hThread) == (DWORD)-1) {
    failure = GetLastError(); TerminateProcess(child.hProcess, 1); goto fail;
  }
  CloseHandle(child.hThread);
  CloseHandle(input_read); CloseHandle(output_write);
  DeleteProcThreadAttributeList(attributes); HeapFree(GetProcessHeap(), 0, attributes);
  free(arguments);
  return pty;
fail:
  if (child.hThread) CloseHandle(child.hThread);
  if (input_read) CloseHandle(input_read);
  if (output_write) CloseHandle(output_write);
  if (attributes) { DeleteProcThreadAttributeList(attributes); HeapFree(GetProcessHeap(), 0, attributes); }
  free(arguments);
  mai_windows_pty_destroy(pty);
  *error = failure;
  return NULL;
}

int mai_windows_pty_read(MaiWindowsPTY *pty, void *buffer, uint32_t count, uint32_t *error) {
  DWORD read = 0;
  if (ReadFile(pty->output, buffer, count, &read, NULL)) return (int)read;
  *error = GetLastError();
  return *error == ERROR_BROKEN_PIPE ? 0 : -1;
}

int mai_windows_pty_register_writer(MaiWindowsPTY *pty, uint32_t *error) {
  HANDLE thread = NULL;
  if (!DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(),
      &thread, 0, FALSE, DUPLICATE_SAME_ACCESS)) { *error = GetLastError(); return 0; }
  AcquireSRWLockExclusive(&pty->lock);
  pty->writer = thread;
  ReleaseSRWLockExclusive(&pty->lock);
  return 1;
}

int mai_windows_pty_write(MaiWindowsPTY *pty, const void *buffer, uint32_t count, uint32_t *error) {
  DWORD written = 0;
  if (WriteFile(pty->input, buffer, count, &written, NULL)) return (int)written;
  *error = GetLastError();
  return -1;
}

void mai_windows_pty_cancel_writer(MaiWindowsPTY *pty) {
  AcquireSRWLockShared(&pty->lock);
  if (pty->writer) CancelSynchronousIo(pty->writer);
  ReleaseSRWLockShared(&pty->lock);
}

int mai_windows_pty_resize(MaiWindowsPTY *pty, int columns, int rows, uint32_t *error) {
  AcquireSRWLockShared(&pty->lock);
  COORD size = {(SHORT)columns, (SHORT)rows};
  HRESULT result = pty->console ? pty->resize(pty->console, size) : S_OK;
  ReleaseSRWLockShared(&pty->lock);
  if (FAILED(result)) { *error = (DWORD)result; return 0; }
  return 1;
}

int mai_windows_pty_wait(MaiWindowsPTY *pty, uint32_t milliseconds, uint32_t *status, uint32_t *error) {
  DWORD waited = WaitForSingleObject(pty->process, milliseconds);
  if (waited == WAIT_TIMEOUT) return 0;
  DWORD code = 0;
  if (waited == WAIT_OBJECT_0 && GetExitCodeProcess(pty->process, &code)) { *status = code; return 1; }
  *error = GetLastError(); return -1;
}

void mai_windows_pty_terminate(MaiWindowsPTY *pty) { TerminateJobObject(pty->job, 1); }

void mai_windows_pty_finish_input(MaiWindowsPTY *pty) {
  if (pty->input) { CloseHandle(pty->input); pty->input = NULL; }
}

void mai_windows_pty_close_console(MaiWindowsPTY *pty) {
  AcquireSRWLockExclusive(&pty->lock);
  HPCON console = pty->console; pty->console = NULL;
  ReleaseSRWLockExclusive(&pty->lock);
  if (console) pty->close(console);
}

void mai_windows_pty_destroy(MaiWindowsPTY *pty) {
  if (!pty) return;
  // Failed startup has no reader. Closing its output first prevents legacy
  // ClosePseudoConsole from waiting forever for an undrained shutdown frame.
  if (pty->output) { CloseHandle(pty->output); pty->output = NULL; }
  if (pty->job) TerminateJobObject(pty->job, 1);
  mai_windows_pty_close_console(pty);
  if (pty->input) CloseHandle(pty->input);
  if (pty->writer) CloseHandle(pty->writer);
  if (pty->process) CloseHandle(pty->process);
  if (pty->job) CloseHandle(pty->job);
  free(pty);
}
#endif
