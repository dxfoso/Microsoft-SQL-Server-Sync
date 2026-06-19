#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_log.h"
#include "utils.h"

namespace {

using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOEXW*);

void LogWindowsVersion() {
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) {
    LogStartupEvent(L"Unable to query Windows version. Continuing startup.");
    return;
  }

  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
      GetProcAddress(ntdll, "RtlGetVersion"));
  if (rtl_get_version == nullptr) {
    LogStartupEvent(L"Unable to query Windows version. Continuing startup.");
    return;
  }

  OSVERSIONINFOEXW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  if (rtl_get_version(&version) != 0) {
    LogStartupEvent(L"Unable to query Windows version. Continuing startup.");
    return;
  }

  wchar_t version_message[128];
  swprintf_s(version_message, L"Detected Windows version %lu.%lu build %lu",
             version.dwMajorVersion, version.dwMinorVersion,
             version.dwBuildNumber);
  LogStartupEvent(version_message);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  LogStartupEvent(L"Native wWinMain starting");
  LogWindowsVersion();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SQL Sync Agent", origin, size)) {
    LogStartupEvent(L"Native window create failed");
    return EXIT_FAILURE;
  }
  LogStartupEvent(L"Native window create succeeded");
  window.SetQuitOnClose(true);

  ::MSG msg;
  LogStartupEvent(L"Native message pump starting");
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  LogStartupEvent(L"Native message pump exiting");
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
