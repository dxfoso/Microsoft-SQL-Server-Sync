#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwctype>
#include <filesystem>
#include <functional>

#include "flutter_window.h"
#include "startup_log.h"
#include "utils.h"

namespace {

using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOEXW*);
HANDLE g_instance_mutex = nullptr;

std::wstring ToLowerInvariant(std::wstring value) {
  for (auto& ch : value) {
    ch = static_cast<wchar_t>(towlower(ch));
  }
  return value;
}

bool HasEnvironmentVariable(const wchar_t* name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  return size != 0 || GetLastError() != ERROR_ENVVAR_NOT_FOUND;
}

std::filesystem::path GetExecutableDirectory() {
  wchar_t path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    LogStartupLastError(L"Unable to resolve executable path");
    return std::filesystem::current_path();
  }

  return std::filesystem::path(path).parent_path();
}

std::wstring GetInstanceMutexName() {
  auto executable_directory = GetExecutableDirectory().wstring();
  if (executable_directory.empty()) {
    return L"Local\\MicrosoftSqlServerSyncAgent";
  }

  const auto normalized = ToLowerInvariant(executable_directory);
  const size_t hash = std::hash<std::wstring>{}(normalized);
  wchar_t mutex_name[128];
  swprintf_s(mutex_name, L"Local\\MicrosoftSqlServerSyncAgent_%016llX",
             static_cast<unsigned long long>(hash));
  return mutex_name;
}

void ConfigureEngineSwitches() {
  if (HasEnvironmentVariable(L"FLUTTER_ENGINE_SWITCHES")) {
    LogStartupEvent(
        L"Flutter engine switches already supplied. Keeping existing values.");
    return;
  }

  if (!HasEnvironmentVariable(L"SYNC_WINDOWS_AGENT_ENABLE_SOFTWARE_RENDERING")) {
    LogStartupEvent(L"Software rendering override not requested. Using engine defaults.");
    return;
  }

  SetEnvironmentVariableW(L"FLUTTER_ENGINE_SWITCHES", L"1");
  SetEnvironmentVariableW(L"FLUTTER_ENGINE_SWITCH_1",
                          L"enable-software-rendering=true");
  LogStartupEvent(L"Enabled Flutter software rendering override");
}

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

bool AcquireSingleInstanceMutex() {
  const auto mutex_name = GetInstanceMutexName();
  g_instance_mutex = CreateMutexW(nullptr, FALSE, mutex_name.c_str());
  if (g_instance_mutex == nullptr) {
    LogStartupLastError(L"CreateMutexW failed for single-instance guard");
    return true;
  }

  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    LogStartupEvent(L"Another sync_windows_agent instance is already running. Exiting duplicate launch.");
    CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
    return false;
  }

  return true;
}

void ReleaseSingleInstanceMutex() {
  if (g_instance_mutex != nullptr) {
    CloseHandle(g_instance_mutex);
    g_instance_mutex = nullptr;
  }
}

bool ConsumeStartMinimizedFlag(std::vector<std::string>* arguments) {
  if (arguments == nullptr) {
    return false;
  }

  bool start_minimized = false;
  std::vector<std::string> filtered_arguments;
  filtered_arguments.reserve(arguments->size());
  for (const auto& argument : *arguments) {
    if (argument == "--start-minimized") {
      start_minimized = true;
      continue;
    }
    filtered_arguments.push_back(argument);
  }

  *arguments = std::move(filtered_arguments);
  return start_minimized;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  LogStartupEvent(L"Native wWinMain starting");
  LogWindowsVersion();
  ConfigureEngineSwitches();
  if (!AcquireSingleInstanceMutex()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const auto data_path = GetExecutableDirectory() / L"data";
  LogStartupEvent(L"Flutter data path: " + data_path.wstring());
  flutter::DartProject project(data_path.wstring());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool start_minimized =
      ConsumeStartMinimizedFlag(&command_line_arguments);

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SQL Sync Agent", origin, size)) {
    if (!window.startup_failure_details().empty()) {
      LogStartupEvent(L"Native startup failure detail: " +
                      window.startup_failure_details());
    }
    LogStartupLastError(L"Native window create failed last_error");
    LogStartupEvent(L"Native window create failed");
    ReleaseSingleInstanceMutex();
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
  ReleaseSingleInstanceMutex();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
