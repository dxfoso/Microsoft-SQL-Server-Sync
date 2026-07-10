#include "flutter_window.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "startup_log.h"

namespace {

constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT_PTR kTrayIconId = 1;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }

  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return L"";
  }

  std::wstring wide(size, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()), wide.data(), size);
  return wide;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_minimized)
    : start_minimized_(start_minimized), project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  startup_failure_details_.clear();
  LogStartupEvent(L"FlutterWindow::OnCreate start");
  if (!Win32Window::OnCreate()) {
    startup_failure_details_ = L"Win32Window::OnCreate returned false";
    LogStartupEvent(L"FlutterWindow::OnCreate base failed");
    return false;
  }

  RECT frame = GetClientArea();
  wchar_t frame_message[160];
  swprintf_s(frame_message,
             L"FlutterWindow client area width=%ld height=%ld left=%ld top=%ld",
             frame.right - frame.left, frame.bottom - frame.top, frame.left,
             frame.top);
  LogStartupEvent(frame_message);

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  SetLastError(ERROR_SUCCESS);
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  LogStartupLastError(
      L"FlutterWindow::OnCreate FlutterViewController creation last_error");

  if (!flutter_controller_) {
    startup_failure_details_ = L"FlutterViewController allocation returned null";
    LogStartupEvent(
        L"FlutterWindow::OnCreate FlutterViewController allocation returned null");
    return false;
  }

  const bool has_engine = flutter_controller_->engine() != nullptr;
  const bool has_view = flutter_controller_->view() != nullptr;
  if (!has_engine || !has_view) {
    wchar_t controller_message[160];
    swprintf_s(
        controller_message,
        L"FlutterWindow::OnCreate controller state engine=%ls view=%ls",
        has_engine ? L"present" : L"null",
        has_view ? L"present" : L"null");
    LogStartupEvent(controller_message);
    startup_failure_details_ =
        L"FlutterViewController initialized with missing engine/view";
    return false;
  }

  LogStartupEvent(L"FlutterWindow::OnCreate RegisterPlugins start");
  RegisterPlugins(flutter_controller_->engine());
  LogStartupEvent(L"FlutterWindow::OnCreate RegisterPlugins complete");
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
        if (call.method_name() == "setWindowTitle") {
          const auto window_handle = GetHandle();
          if (window_handle == nullptr) {
            result->Error("window_not_found", "Window handle is not available.");
            return;
          }

          const auto* arguments =
              std::get_if<std::string>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_title", "Window title must be a string.");
            return;
          }

          const auto title = Utf8ToWide(*arguments);
          SetWindowText(window_handle, title.empty() ? L"SQL Sync Agent" : title.c_str());
          result->Success();
          return;
        }
        if (call.method_name() == "setTrayProgress") {
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments == nullptr) {
            result->Error("invalid_tray_progress",
                          "Tray progress arguments must be a map.");
            return;
          }

          bool active = false;
          int progress = 0;
          std::string status;
          for (const auto& entry : *arguments) {
            const auto* key = std::get_if<std::string>(&entry.first);
            if (key == nullptr) {
              continue;
            }
            if (*key == "active") {
              if (const auto* active_value =
                      std::get_if<bool>(&entry.second)) {
                active = *active_value;
              }
            } else if (*key == "progress") {
              if (const auto* progress_int32 =
                      std::get_if<int32_t>(&entry.second)) {
                progress = *progress_int32;
              } else if (const auto* progress_int64 =
                             std::get_if<int64_t>(&entry.second)) {
                progress = static_cast<int>(*progress_int64);
              } else if (const auto* progress_double =
                             std::get_if<double>(&entry.second)) {
                progress = static_cast<int>(*progress_double);
              }
            } else if (*key == "status") {
              if (const auto* status_value =
                      std::get_if<std::string>(&entry.second)) {
                status = *status_value;
              }
            }
          }

          tray_progress_active_ = active;
          tray_progress_ = std::clamp(progress, 0, 100);
          const auto status_text = Utf8ToWide(status);
          tray_tooltip_ = L"SQL Sync Agent";
          if (tray_progress_active_) {
            tray_tooltip_ += L" - " +
                             (status_text.empty() ? L"Syncing" : status_text);
            tray_tooltip_ += L" (" + std::to_wstring(tray_progress_) + L"%)";
          }
          UpdateTrayIcon();
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  const auto flutter_view_window = flutter_controller_->view()->GetNativeWindow();
  if (flutter_view_window == nullptr) {
    startup_failure_details_ =
        L"Flutter view native window handle is null after controller initialization";
    LogStartupEvent(L"FlutterWindow::OnCreate Flutter view native window handle is null");
    return false;
  }

  LogStartupEvent(L"FlutterWindow::OnCreate SetChildContent start");
  SetChildContent(flutter_view_window);
  LogStartupEvent(L"FlutterWindow::OnCreate SetChildContent complete");
  if (start_minimized_) {
    LogStartupEvent(L"FlutterWindow::OnCreate launching minimized to tray");
    allow_tray_minimize_ = true;
    MinimizeToTray();
  } else {
    LogStartupEvent(L"FlutterWindow::OnCreate show window immediately");
    this->Show();
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    LogStartupEvent(L"FlutterWindow first frame callback");
    startup_ui_ready_ = true;
    allow_tray_minimize_ = true;
    const auto window_handle = GetHandle();
    if (window_handle != nullptr && !start_minimized_) {
      this->Show();
      SetForegroundWindow(window_handle);
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  LogStartupEvent(L"FlutterWindow::OnCreate force redraw");
  flutter_controller_->ForceRedraw();

  return true;
}

const std::wstring& FlutterWindow::startup_failure_details() const {
  return startup_failure_details_;
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

HICON FlutterWindow::CreateTrayProgressIcon(int progress) const {
  auto app_icon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  if (app_icon == nullptr) {
    app_icon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  if (app_icon == nullptr) {
    return nullptr;
  }

  auto copied_icon = static_cast<HICON>(
      CopyImage(app_icon, IMAGE_ICON, 32, 32, LR_COPYFROMRESOURCE));
  if (copied_icon == nullptr) {
    return nullptr;
  }

  ICONINFO icon_info{};
  if (GetIconInfo(copied_icon, &icon_info) == FALSE ||
      icon_info.hbmColor == nullptr || icon_info.hbmMask == nullptr) {
    DestroyIcon(copied_icon);
    if (icon_info.hbmColor != nullptr) {
      DeleteObject(icon_info.hbmColor);
    }
    if (icon_info.hbmMask != nullptr) {
      DeleteObject(icon_info.hbmMask);
    }
    return nullptr;
  }

  BITMAP bitmap{};
  if (GetObject(icon_info.hbmColor, sizeof(bitmap), &bitmap) == 0) {
    DeleteObject(icon_info.hbmColor);
    DeleteObject(icon_info.hbmMask);
    DestroyIcon(copied_icon);
    return nullptr;
  }

  const int width = std::max(1L, bitmap.bmWidth);
  const int height = std::max(1L, bitmap.bmHeight);
  const int diameter = std::min(width, height);
  const int margin = std::max(1, diameter / 8);
  const int pen_width = std::max(1, diameter / 8);
  const int center_x = width / 2;
  const int center_y = height / 2;
  const int radius = std::max(1, diameter / 2 - margin);

  HDC dc = CreateCompatibleDC(nullptr);
  if (dc == nullptr) {
    DeleteObject(icon_info.hbmColor);
    DeleteObject(icon_info.hbmMask);
    DestroyIcon(copied_icon);
    return nullptr;
  }

  const auto old_bitmap = SelectObject(dc, icon_info.hbmColor);
  const auto pen_color = progress >= 100 ? RGB(34, 197, 94) : RGB(37, 99, 235);
  HPEN pen = CreatePen(PS_SOLID, pen_width, pen_color);
  HGDIOBJ old_pen = SelectObject(dc, pen);
  HGDIOBJ old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));

  const int left = center_x - radius;
  const int top = center_y - radius;
  const int right = center_x + radius;
  const int bottom = center_y + radius;
  if (progress >= 100) {
    Ellipse(dc, left, top, right, bottom);
  } else {
    const double sweep_degrees = progress <= 0 ? 70.0 : progress * 3.6;
    constexpr double kPi = 3.14159265358979323846;
    const double end_angle = (90.0 - sweep_degrees) * kPi / 180.0;
    const int end_x = center_x + static_cast<int>(radius * std::cos(end_angle));
    const int end_y = center_y - static_cast<int>(radius * std::sin(end_angle));
    Arc(dc, left, top, right, bottom, center_x + radius, center_y, end_x,
        end_y);
  }

  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  SelectObject(dc, old_bitmap);
  DeleteObject(pen);
  DeleteDC(dc);

  const auto progress_icon = CreateIconIndirect(&icon_info);
  DeleteObject(icon_info.hbmColor);
  DeleteObject(icon_info.hbmMask);
  DestroyIcon(copied_icon);
  return progress_icon;
}

void FlutterWindow::UpdateTrayIcon(bool notify_shell) {
  if (!tray_icon_visible_ && notify_shell) {
    return;
  }

  HICON next_dynamic_icon = nullptr;
  if (tray_progress_active_) {
    next_dynamic_icon = CreateTrayProgressIcon(tray_progress_);
  }
  if (tray_dynamic_icon_ != nullptr) {
    DestroyIcon(tray_dynamic_icon_);
  }
  tray_dynamic_icon_ = next_dynamic_icon;

  auto app_icon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  if (app_icon == nullptr) {
    app_icon = LoadIcon(nullptr, IDI_APPLICATION);
  }
  tray_icon_data_.hIcon = tray_dynamic_icon_ == nullptr ? app_icon : tray_dynamic_icon_;
  wcscpy_s(tray_icon_data_.szTip, _countof(tray_icon_data_.szTip),
           tray_tooltip_.c_str());
  if (notify_shell && tray_icon_visible_) {
    Shell_NotifyIcon(NIM_MODIFY, &tray_icon_data_);
  }
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

  UpdateTrayIcon(false);

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
  if (tray_dynamic_icon_ != nullptr) {
    DestroyIcon(tray_dynamic_icon_);
    tray_dynamic_icon_ = nullptr;
  }
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

bool FlutterWindow::HandleCloseRequest() {
  const auto window_handle = GetHandle();
  if (window_handle == nullptr) {
    return false;
  }

  LogStartupEvent(L"FlutterWindow close confirmation");
  const int choice = MessageBoxW(
      window_handle,
      L"Do you want to minimize SQL Sync Agent to the tray instead of closing it?\n\n"
      L"Yes: minimize to tray\nNo: close the app\nCancel: keep the window open",
      L"Close SQL Sync Agent",
      MB_ICONQUESTION | MB_YESNOCANCEL | MB_DEFBUTTON1);

  if (choice == IDYES) {
    MinimizeToTray();
    return true;
  }
  if (choice == IDCANCEL) {
    return true;
  }
  return false;
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
      if (HandleCloseRequest()) {
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
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
