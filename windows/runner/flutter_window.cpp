#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include <commctrl.h>
#include <windowsx.h>

#pragma comment(lib, "comctl32.lib")

#include "flutter/generated_plugin_registrant.h"

namespace {
// Flutter 子窗口将标题和边框命中交回宿主，系统继续处理拖动、贴靠及缩放。
LRESULT CALLBACK ChromeChildProc(HWND hwnd, UINT message, WPARAM wparam,
                                LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  auto owner = reinterpret_cast<Win32Window*>(data);
  if (message == WM_NCHITTEST &&
      owner->HitTestChrome({GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}) != HTCLIENT) {
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(hwnd, ChromeChildProc, id);
  return DefSubclassProc(hwnd, message, wparam, lparam);
}
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  SetWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                    ChromeChildProc, 1, reinterpret_cast<DWORD_PTR>(this));

  // 仅适配当前窗口的外观；所有调用都在平台主线程处理。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "opennote/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto& method = call.method_name();
        if (method == "setChromeRegions") {
          const auto* values = call.arguments()
              ? std::get_if<flutter::EncodableList>(call.arguments()) : nullptr;
          if (!values) {
            result->Error("invalid-arguments", "窗口区域必须为列表");
            return;
          }
          std::vector<ChromeRegion> regions;
          for (const auto& value : *values) {
            const auto* map = std::get_if<flutter::EncodableMap>(&value);
            if (!map) {
              result->Error("invalid-arguments", "窗口区域格式错误");
              return;
            }
            auto number = [&](const char* key) -> std::optional<double> {
              auto item = map->find(flutter::EncodableValue(key));
              if (item == map->end()) return std::nullopt;
              const auto* v = std::get_if<double>(&item->second);
              return v ? std::optional<double>(*v) : std::nullopt;
            };
            auto x = number("x"), y = number("y"), width = number("width"),
                 height = number("height"), role = number("role");
            if (!x || !y || !width || !height || !role) {
              result->Error("invalid-arguments", "窗口区域缺少坐标");
              return;
            }
            regions.push_back({*x, *y, *width, *height, *role == 1});
          }
          SetChromeRegions(std::move(regions));
          framework_chrome_ready_ = true;
          result->Success(flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE));
          return;
        }
        if (method == "minimize" || method == "toggleMaximize" ||
            method == "requestClose") {
          if (method == "requestClose") {
            // 必须经过 Flutter 的退出请求，禁止绕过待保存草稿和 OCR 排空。
            PostMessage(GetHandle(), WM_CLOSE, 0, 0);
          } else if (!IsFullscreen()) {
            ShowWindow(GetHandle(), method == "minimize" ? SW_MINIMIZE :
                       IsZoomed(GetHandle()) ? SW_RESTORE : SW_MAXIMIZE);
          }
          result->Success();
          return;
        }
        if (method != "setFullscreen") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
            ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) {
          result->Error("invalid-arguments", "全屏状态必须为布尔值");
          return;
        }
        if (!SetFullscreen(*enabled)) {
          result->Error("fullscreen-failed", "无法切换窗口全屏状态",
                        flutter::EncodableValue(static_cast<int64_t>(GetLastError())));
          return;
        }
        result->Success(flutter::EncodableValue(IsFullscreen()));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                         ChromeChildProc, 1);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::OnMaximizeInteractionChanged(bool hovered, bool pressed) {
  if (!window_channel_) return;
  window_channel_->InvokeMethod("maximizeInteraction",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("hovered"), flutter::EncodableValue(hovered)},
          {flutter::EncodableValue("pressed"), flutter::EncodableValue(pressed)},
      }));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE && framework_chrome_ready_ && window_channel_) {
    // WebView 等辅助窗口可能影响引擎的“最后一个窗口”判断。
    // 显式走可取消退出，等待既有草稿保存和后台排空，再由引擎结束进程。
    window_channel_->InvokeMethod("requestAppExit", nullptr);
    return 0;
  }
  if (message == WM_SIZE && window_channel_) {
    window_channel_->InvokeMethod("windowState",
        std::make_unique<flutter::EncodableValue>(IsZoomed(hwnd) != FALSE));
  }
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
