#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "startup_log.h"

namespace {

constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT_PTR kTrayIconId = 1;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  LogStartupEvent(L"FlutterWindow::OnCreate start");
  if (!Win32Window::OnCreate()) {
    LogStartupEvent(L"FlutterWindow::OnCreate base failed");
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "sync_windows_agent/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) {
        if (call.method_name() == "minimizeWindow") {
          const auto window_handle = GetHandle();
          if (window_handle == nullptr) {
            result->Error("window_not_found", "Window handle is not available.");
            return;
          }

          LogStartupEvent(L"FlutterWindow minimizeWindow method called");
          MinimizeToTray();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  LogStartupEvent(L"FlutterWindow::OnCreate show window immediately");
  Show();
  SetForegroundWindow(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    LogStartupEvent(L"FlutterWindow first frame callback");
    startup_ui_ready_ = true;
    this->Show();
    allow_tray_minimize_ = true;
    SetForegroundWindow(GetHandle());
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  LogStartupEvent(L"FlutterWindow::OnCreate force redraw");
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  LogStartupEvent(L"FlutterWindow::OnDestroy");
  RemoveTrayIcon();
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_visible_) {
    return;
  }

  LogStartupEvent(L"FlutterWindow::AddTrayIcon");
  const auto window_handle = GetHandle();
  if (window_handle == nullptr) {
    return;
  }

  tray_icon_data_ = {};
  tray_icon_data_.cbSize = sizeof(NOTIFYICONDATA);
  tray_icon_data_.uFlags = NIF_ICON | NIF_TIP | NIF_MESSAGE;
  tray_icon_data_.uCallbackMessage = kTrayIconMessage;
  tray_icon_data_.hWnd = window_handle;
  tray_icon_data_.uID = kTrayIconId;

  auto app_icon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  if (app_icon == nullptr) {
    app_icon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  tray_icon_data_.hIcon = app_icon;
  wcscpy_s(
      tray_icon_data_.szTip, _countof(tray_icon_data_.szTip), L"SQL Sync Agent");

  if (Shell_NotifyIcon(NIM_ADD, &tray_icon_data_) == FALSE) {
    return;
  }

  tray_icon_visible_ = true;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_visible_) {
    return;
  }

  LogStartupEvent(L"FlutterWindow::RemoveTrayIcon");
  tray_icon_data_.uFlags = 0;
  tray_icon_visible_ = false;
  Shell_NotifyIcon(NIM_DELETE, &tray_icon_data_);
  tray_icon_data_ = {};
}

void FlutterWindow::MinimizeToTray() {
  const auto window_handle = GetHandle();
  if (window_handle == nullptr) {
    return;
  }

  LogStartupEvent(L"FlutterWindow::MinimizeToTray");
  AddTrayIcon();
  ShowWindow(window_handle, SW_HIDE);
}

void FlutterWindow::RestoreFromTray() {
  const auto window_handle = GetHandle();
  if (window_handle == nullptr) {
    return;
  }

  LogStartupEvent(L"FlutterWindow::RestoreFromTray");
  RemoveTrayIcon();
  ShowWindow(window_handle, SW_RESTORE);
  ShowWindow(window_handle, SW_SHOW);
  SetForegroundWindow(window_handle);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_CLOSE:
      LogStartupEvent(L"FlutterWindow WM_CLOSE");
      if (!startup_ui_ready_) {
        LogStartupEvent(L"FlutterWindow ignoring startup close");
        return 0;
      }
      break;
    case WM_DESTROY:
      LogStartupEvent(L"FlutterWindow WM_DESTROY");
      break;
    case WM_NCDESTROY:
      LogStartupEvent(L"FlutterWindow WM_NCDESTROY");
      break;
    case WM_SYSCOMMAND:
      if ((wparam & 0xFFF0) == SC_CLOSE) {
        LogStartupEvent(L"FlutterWindow WM_SYSCOMMAND SC_CLOSE");
        if (!startup_ui_ready_) {
          LogStartupEvent(L"FlutterWindow ignoring startup system close");
          return 0;
        }
      }
      break;
    case kTrayIconMessage:
      LogStartupEvent(L"FlutterWindow tray icon message");
      if (
          lparam == WM_LBUTTONUP ||
          lparam == WM_LBUTTONDBLCLK ||
          lparam == WM_RBUTTONUP) {
        RestoreFromTray();
      }
      return 0;
    case WM_SHOWWINDOW:
      LogStartupEvent(L"FlutterWindow WM_SHOWWINDOW");
      break;
    case WM_SIZE:
      if (wparam == SIZE_MINIMIZED) {
        LogStartupEvent(L"FlutterWindow WM_SIZE minimized");
        if (!allow_tray_minimize_) {
          LogStartupEvent(L"FlutterWindow ignoring startup minimize");
          ShowWindow(hwnd, SW_RESTORE);
          ShowWindow(hwnd, SW_SHOW);
          SetForegroundWindow(hwnd);
          return 0;
        }
      }
      if (wparam == SIZE_MINIMIZED) {
        MinimizeToTray();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
