#ifndef RUNNER_STARTUP_LOG_H_
#define RUNNER_STARTUP_LOG_H_

#include <windows.h>

#include <string>

void LogStartupEvent(const std::wstring& message);
std::wstring DescribeWindowsError(DWORD error_code);
void LogStartupWindowsError(const std::wstring& context, DWORD error_code);
void LogStartupLastError(const std::wstring& context);

#endif  // RUNNER_STARTUP_LOG_H_
