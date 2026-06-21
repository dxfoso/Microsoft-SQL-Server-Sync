#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();
  const std::wstring& startup_failure_details() const;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AddTrayIcon();
  void RemoveTrayIcon();
  void MinimizeToTray();
  void RestoreFromTray();
  bool HandleCloseRequest();

  bool startup_ui_ready_ = false;
  bool allow_tray_minimize_ = false;
  bool tray_icon_visible_ = false;
  NOTIFYICONDATA tray_icon_data_{};

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native window controls exposed to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  std::wstring startup_failure_details_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
