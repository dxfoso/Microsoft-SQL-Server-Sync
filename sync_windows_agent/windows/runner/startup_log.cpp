#include "startup_log.h"

#include <windows.h>

#include <filesystem>
#include <string>
#include <vector>

namespace {

std::filesystem::path GetStartupLogPath() {
  wchar_t module_path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return {};
  }

  return std::filesystem::path(module_path).parent_path() /
         L"sync_windows_agent_startup.log";
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }

  const int required = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (required <= 0) {
    return {};
  }

  std::vector<char> buffer(static_cast<size_t>(required));
  if (WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, buffer.data(),
                          required, nullptr, nullptr) <= 0) {
    return {};
  }

  return std::string(buffer.data());
}

std::wstring FormatTimestamp() {
  SYSTEMTIME now{};
  GetLocalTime(&now);

  wchar_t formatted[64];
  swprintf_s(formatted, L"[%04u-%02u-%02uT%02u:%02u:%02u.%03u] ",
             now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
             now.wSecond, now.wMilliseconds);
  return formatted;
}

}  // namespace

void LogStartupEvent(const std::wstring& message) {
  try {
    const auto log_path = GetStartupLogPath();
    if (log_path.empty()) {
      return;
    }

    const std::wstring line = FormatTimestamp() + message + L"\r\n";
    const std::string utf8_line = WideToUtf8(line);
    if (utf8_line.empty()) {
      return;
    }

    HANDLE file = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
      return;
    }

    DWORD bytes_written = 0;
    WriteFile(file, utf8_line.data(),
              static_cast<DWORD>(utf8_line.size()), &bytes_written, nullptr);
    CloseHandle(file);
  } catch (...) {
    // Best effort only.
  }
}
