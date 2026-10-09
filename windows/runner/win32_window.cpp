#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>
#include <algorithm>
#include <utility>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// 数值来自 Windows SDK；旧 SDK 也能编译，旧系统忽略不支持的圆角属性。
constexpr DWORD kWindowCornerPreference = 33;
constexpr DWORD kDoNotRound = 1;
constexpr DWORD kRound = 2;

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size,
                         bool center_in_work_area) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = center_in_work_area
      ? MonitorFromWindow(nullptr, MONITOR_DEFAULTTOPRIMARY)
      : MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;
  int x = Scale(origin.x, scale_factor);
  int y = Scale(origin.y, scale_factor);
  int width = Scale(size.width, scale_factor);
  int height = Scale(size.height, scale_factor);
  if (center_in_work_area) {
    MONITORINFO info = {sizeof(MONITORINFO)};
    if (!GetMonitorInfo(monitor, &info)) return false;
    const int work_width = info.rcWork.right - info.rcWork.left;
    const int work_height = info.rcWork.bottom - info.rcWork.top;
    const int margin = Scale(16, scale_factor);
    // 优先保留边缘；小屏时保证窗口完整可见，并遵守可用的最小尺寸。
    width = std::min(width, std::min(work_width,
        std::max(Scale(1024, scale_factor), work_width - 2 * margin)));
    height = std::min(height, std::min(work_height,
        std::max(Scale(640, scale_factor), work_height - 2 * margin)));
    x = info.rcWork.left + (work_width - width) / 2;
    y = info.rcWork.top + (work_height - height) / 2;
  }

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      x, y, width, height,
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

void Win32Window::SetChromeRegions(std::vector<ChromeRegion> regions) {
  chrome_regions_ = std::move(regions);
  if (chrome_regions_.empty()) {
    if (maximize_pressed_ && GetCapture() == window_handle_) ReleaseCapture();
    UpdateMaximizeInteraction(false, false);
  }
  if (!chrome_enabled_) {
    chrome_enabled_ = true;
    // 自绘标题栏不保留系统标题绘制；缩放、系统菜单和最小／最大化仍可用。
    const LONG_PTR style = GetWindowLongPtr(window_handle_, GWL_STYLE);
    SetWindowLongPtr(window_handle_, GWL_STYLE,
                     style & ~static_cast<LONG_PTR>(WS_CAPTION));
    UpdateWindowFrame();
    // 重新计算客户区，保留 WS_THICKFRAME 和各窗口控制能力。
    SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
}

void Win32Window::UpdateMaximizeInteraction(bool hovered, bool pressed) {
  if (maximize_hovered_ == hovered && maximize_pressed_ == pressed) return;
  maximize_hovered_ = hovered;
  maximize_pressed_ = pressed;
  OnMaximizeInteractionChanged(hovered, hovered && pressed);
}

void Win32Window::OnMaximizeInteractionChanged(bool, bool) {}

void Win32Window::UpdateWindowFrame() {
  if (!window_handle_ || !chrome_enabled_) return;
  const bool square = fullscreen_ || IsZoomed(window_handle_);
  const DWORD preference = square ? kDoNotRound : kRound;
  DwmSetWindowAttribute(window_handle_, kWindowCornerPreference,
                        &preference, sizeof(preference));
  // 为自绘客户区保留 DWM 边框、阴影和四角裁剪；全屏／最大化不留边缘。
  const int edge = square ? 0 : 1;
  const MARGINS margins = {edge, edge, edge, edge};
  DwmExtendFrameIntoClientArea(window_handle_, &margins);
}

LRESULT Win32Window::HitTestChrome(POINT point) const {
  if (!chrome_enabled_ || fullscreen_) return HTCLIENT;
  RECT bounds{};
  GetClientRect(window_handle_, &bounds);
  ScreenToClient(window_handle_, &point);
  const UINT dpi = GetDpiForWindow(window_handle_);
  const int border = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                     GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
  if (!IsZoomed(window_handle_)) {
    const bool left = point.x < border;
    const bool right = point.x >= bounds.right - border;
    const bool top = point.y < border;
    const bool bottom = point.y >= bounds.bottom - border;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
  }
  const double scale = dpi / 96.0;
  const double x = point.x / scale;
  const double y = point.y / scale;
  for (const auto& region : chrome_regions_) {
    if (x >= region.x && x < region.x + region.width &&
        y >= region.y && y < region.y + region.height) {
      return region.maximize ? HTMAXBUTTON : HTCAPTION;
    }
  }
  return HTCLIENT;
}

namespace {
// SetWindowLongPtr 返回零也可能成功，必须检查本次 Win32 错误。
bool SetWindowAttribute(HWND window, int index, LONG_PTR value) {
  SetLastError(ERROR_SUCCESS);
  return SetWindowLongPtr(window, index, value) != 0 ||
         GetLastError() == ERROR_SUCCESS;
}
}

bool Win32Window::SetFullscreen(bool enabled) {
  if (!window_handle_) return false;
  if (enabled == fullscreen_) return true;

  const LONG_PTR old_style = GetWindowLongPtr(window_handle_, GWL_STYLE);
  const LONG_PTR old_ex_style = GetWindowLongPtr(window_handle_, GWL_EXSTYLE);
  WINDOWPLACEMENT old_placement = {sizeof(WINDOWPLACEMENT)};
  RECT old_bounds{};
  if (!GetWindowPlacement(window_handle_, &old_placement) ||
      !GetWindowRect(window_handle_, &old_bounds)) return false;

  if (enabled) {
    if (maximize_pressed_ && GetCapture() == window_handle_) ReleaseCapture();
    UpdateMaximizeInteraction(false, false);
    windowed_style_ = old_style;
    windowed_ex_style_ = old_ex_style;
    windowed_placement_ = old_placement;
    fullscreen_ = true;
    UpdateWindowFrame();
    const LONG_PTR fullscreen_style = old_style &
        ~(static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW) | WS_MAXIMIZE | WS_MINIMIZE);
    const LONG_PTR fullscreen_ex_style = old_ex_style &
        ~(static_cast<LONG_PTR>(WS_EX_DLGMODALFRAME) | WS_EX_WINDOWEDGE |
          WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
    if (SetWindowAttribute(window_handle_, GWL_STYLE, fullscreen_style) &&
        SetWindowAttribute(window_handle_, GWL_EXSTYLE, fullscreen_ex_style) &&
        UpdateFullscreenBounds()) return true;
  } else {
    fullscreen_ = false;
    // 窗口状态交给 placement 恢复；预设 WS_MAXIMIZE 会跳过工作区重算。
    const LONG_PTR restored_style = windowed_style_ &
        ~(static_cast<LONG_PTR>(WS_MAXIMIZE) | WS_MINIMIZE);
    if (SetWindowAttribute(window_handle_, GWL_STYLE, restored_style) &&
        SetWindowAttribute(window_handle_, GWL_EXSTYLE, windowed_ex_style_) &&
        SetWindowPlacement(window_handle_, &windowed_placement_) &&
        SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
            SWP_FRAMECHANGED)) {
      UpdateWindowFrame();
      return true;
    }
  }

  // 任一步失败回到调用前状态；不让 Dart 误认为已经切换成功。
  const DWORD error = GetLastError();
  fullscreen_ = !enabled;
  SetWindowAttribute(window_handle_, GWL_STYLE, old_style);
  SetWindowAttribute(window_handle_, GWL_EXSTYLE, old_ex_style);
  SetWindowPlacement(window_handle_, &old_placement);
  SetWindowPos(window_handle_, nullptr, old_bounds.left, old_bounds.top,
      old_bounds.right - old_bounds.left, old_bounds.bottom - old_bounds.top,
      SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  UpdateWindowFrame();
  SetLastError(error);
  return false;
}

bool Win32Window::UpdateFullscreenBounds() {
  MONITORINFO monitor = {sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST),
                      &monitor)) return false;
  const RECT& bounds = monitor.rcMonitor;
  // HWND_TOP 不设置置顶属性；切换到其他应用时仍保留正常的窗口顺序。
  return SetWindowPos(window_handle_, HWND_TOP, bounds.left, bounds.top,
      bounds.right - bounds.left, bounds.bottom - bounds.top,
      SWP_FRAMECHANGED | SWP_NOOWNERZORDER) != FALSE;
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCPAINT:
      if (chrome_enabled_) return 0;
      break;
    case WM_NCACTIVATE:
      if (chrome_enabled_) {
        // 保留系统激活状态，禁止默认过程在 Flutter 上重画旧标题按钮。
        return DefWindowProc(hwnd, message, wparam, -1);
      }
      break;
    case WM_NCCALCSIZE:
      if (chrome_enabled_ && wparam) {
        auto rect = &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0];
        if (!fullscreen_ && IsZoomed(hwnd)) {
          MONITORINFO monitor = {sizeof(MONITORINFO)};
          if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                             &monitor)) {
            *rect = monitor.rcWork;
          }
        }
        return 0;
      }
      break;
    case WM_NCHITTEST:
      if (chrome_enabled_) {
        return HitTestChrome({GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)});
      }
      break;
    case WM_NCMOUSEMOVE:
    case WM_NCMOUSELEAVE:
      if (chrome_enabled_) {
        // HTMAXBUTTON 继续提供 Windows 11 贴靠菜单；不绘制经典标题按钮。
        LRESULT result = 0;
        DwmDefWindowProc(hwnd, message, wparam, lparam, &result);
        if (message == WM_NCMOUSEMOVE) {
          UpdateMaximizeInteraction(!fullscreen_ && wparam == HTMAXBUTTON,
                                    maximize_pressed_);
          TRACKMOUSEEVENT tracking = {sizeof(TRACKMOUSEEVENT),
              TME_LEAVE | TME_NONCLIENT, hwnd, 0};
          TrackMouseEvent(&tracking);
        } else {
          UpdateMaximizeInteraction(false, maximize_pressed_);
        }
        return result;
      }
      break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK:
      if (chrome_enabled_ && !fullscreen_ && wparam == HTMAXBUTTON) {
        // 默认过程按系统按钮的旧位置跟踪点击，会产生重影或点击无效。
        // 按住后捕获鼠标，只在自绘按钮内松开时切换；拖出及失去捕获取消。
        UpdateMaximizeInteraction(true, true);
        SetCapture(hwnd);
        return 0;
      }
      break;
    case WM_MOUSEMOVE:
      if (maximize_pressed_) {
        POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ClientToScreen(hwnd, &point);
        UpdateMaximizeInteraction(HitTestChrome(point) == HTMAXBUTTON, true);
        return 0;
      }
      break;
    case WM_LBUTTONUP:
      if (maximize_pressed_) {
        POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ClientToScreen(hwnd, &point);
        const bool toggle = HitTestChrome(point) == HTMAXBUTTON;
        UpdateMaximizeInteraction(toggle, false);
        if (GetCapture() == hwnd) ReleaseCapture();
        if (toggle) {
          PostMessage(hwnd, WM_SYSCOMMAND,
                      IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
        }
        return 0;
      }
      break;
    case WM_NCLBUTTONUP:
      if (chrome_enabled_ && wparam == HTMAXBUTTON) return 0;
      break;
    case WM_CANCELMODE:
      if (maximize_pressed_) {
        UpdateMaximizeInteraction(false, false);
        if (GetCapture() == hwnd) ReleaseCapture();
      }
      break;
    case WM_CAPTURECHANGED:
      if (maximize_pressed_) UpdateMaximizeInteraction(false, false);
      break;
    case WM_GETMINMAXINFO: {
      auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
      if (fullscreen_) {
        // 高 DPI 小屏全屏仍按显示器实际尺寸，不沿用普通窗口最小逻辑尺寸。
        limits->ptMinTrackSize.x = 1;
        limits->ptMinTrackSize.y = 1;
        return 0;
      }
      // 最小尺寸按当前 DPI 换算，保留阅读、脑图和顶部工具的可操作空间。
      const UINT dpi = GetDpiForWindow(hwnd);
      limits->ptMinTrackSize.x = MulDiv(1024, dpi, 96);
      limits->ptMinTrackSize.y = MulDiv(640, dpi, 96);
      MONITORINFO monitor = {sizeof(MONITORINFO)};
      const bool has_monitor = GetMonitorInfo(
          MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
      if (has_monitor) {
        // 屏幕工作区小于常规最小尺寸时，仍允许完整显示启动窗口。
        limits->ptMinTrackSize.x = std::min(limits->ptMinTrackSize.x,
            monitor.rcWork.right - monitor.rcWork.left);
        limits->ptMinTrackSize.y = std::min(limits->ptMinTrackSize.y,
            monitor.rcWork.bottom - monitor.rcWork.top);
      }
      if (chrome_enabled_) {
        if (has_monitor) {
          // 必须同时限制外框，只有客户区避让任务栏仍会被 Shell 当作全屏。
          limits->ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
          limits->ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
          limits->ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
          limits->ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
        }
      }
      return 0;
    }
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      if (fullscreen_) {
        UpdateFullscreenBounds();
        return 0;
      }
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_DISPLAYCHANGE:
      if (fullscreen_) UpdateFullscreenBounds();
      return 0;
    case WM_SIZE: {
      if (maximize_pressed_ && GetCapture() == hwnd) ReleaseCapture();
      UpdateMaximizeInteraction(false, false);
      // 最小化时保留 Flutter 最后一次有效尺寸，避免把图标客户区当成页面布局。
      if (wparam == SIZE_MINIMIZED) return 0;
      UpdateWindowFrame();
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
    case WM_DWMCOMPOSITIONCHANGED:
      UpdateWindowFrame();
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
