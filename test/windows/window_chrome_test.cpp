#include "win32_window.h"

#include <dwmapi.h>
#include <windowsx.h>
#include <iostream>

namespace {
int failures = 0;

class ChromeWindow : public Win32Window {
 public:
  bool hovered = false;
  bool pressed = false;

 protected:
  void OnMaximizeInteractionChanged(bool hover, bool press) override {
    hovered = hover;
    pressed = press;
  }
};

void Check(bool value, const char* description) {
  std::cout << (value ? "PASS: " : "FAIL: ") << description << '\n';
  if (!value) ++failures;
}

void Pump() {
  MSG message{};
  while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
}

DWORD Corner(HWND window) {
  DWORD preference = 0;
  Check(SUCCEEDED(DwmGetWindowAttribute(window, 33, &preference,
                                       sizeof(preference))), "读取 DWM 圆角策略");
  return preference;
}

POINT MaxPoint(HWND window) {
  const UINT dpi = GetDpiForWindow(window);
  return {MulDiv(940, dpi, 96), MulDiv(28, dpi, 96)};
}

void Press(HWND window) {
  POINT point = MaxPoint(window);
  ClientToScreen(window, &point);
  SendMessage(window, WM_NCLBUTTONDOWN, HTMAXBUTTON,
              MAKELPARAM(point.x, point.y));
}

void Release(HWND window, bool inside = true) {
  POINT point = inside ? MaxPoint(window) : POINT{200, 200};
  SendMessage(window, WM_LBUTTONUP, 0, MAKELPARAM(point.x, point.y));
  Pump();
}
}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  MONITORINFO primary{sizeof(MONITORINFO)};
  Check(GetMonitorInfo(MonitorFromWindow(nullptr, MONITOR_DEFAULTTOPRIMARY),
                       &primary), "获取主屏工作区");
  for (const auto& size : {Win32Window::Size{1440, 900},
                           Win32Window::Size{10000, 10000}}) {
    ChromeWindow centered;
    Check(centered.Create(L"OpenNote centered startup regression",
                          {0, 0}, size, true), "创建居中启动窗口");
    RECT bounds{};
    Check(GetWindowRect(centered.GetHandle(), &bounds), "读取启动窗口边界");
    Check(abs(bounds.left + bounds.right - primary.rcWork.left -
              primary.rcWork.right) <= 1 &&
          abs(bounds.top + bounds.bottom - primary.rcWork.top -
              primary.rcWork.bottom) <= 1,
          "普通尺寸及超大尺寸均在主屏工作区居中");
    Check(bounds.left >= primary.rcWork.left && bounds.top >= primary.rcWork.top &&
          bounds.right <= primary.rcWork.right && bounds.bottom <= primary.rcWork.bottom,
          "高 DPI 下启动窗口完整位于工作区内");
    centered.Destroy();
  }
  ChromeWindow window;
  if (!window.Create(L"OpenNote window chrome regression",
                      {40, 40}, {1100, 720})) return 1;
  HWND hwnd = window.GetHandle();
  window.SetChromeRegions({{20, 12, 800, 32, false}, {920, 10, 40, 36, true}});
  window.Show();
  Pump();
  Check(Corner(hwnd) == 2, "普通窗口明确启用四角圆角");
  const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  Check((style & WS_CAPTION) == 0 && (style & WS_THICKFRAME) &&
        (style & WS_MINIMIZEBOX) && (style & WS_MAXIMIZEBOX),
        "去掉系统标题绘制，保留缩放和最小／最大化能力");
  // 旧版本在圆角合同处即可失败，避免进入默认按钮的阻塞式跟踪循环。
  if (failures) return 1;

  POINT point = MaxPoint(hwnd);
  ClientToScreen(hwnd, &point);
  Check(window.HitTestChrome(point) == HTMAXBUTTON, "自绘最大化保留贴靠命中");
  POINT corner{1, 1};
  ClientToScreen(hwnd, &corner);
  Check(window.HitTestChrome(corner) == HTTOPLEFT, "普通窗口四角保留缩放命中");
  RECT before{};
  GetWindowRect(hwnd, &before);

  SendMessage(hwnd, WM_NCMOUSEMOVE, HTMAXBUTTON, MAKELPARAM(point.x, point.y));
  Check(window.hovered && !window.pressed, "原生最大化悬停传给自绘按钮");
  SendMessage(hwnd, WM_NCMOUSEMOVE, HTCAPTION, MAKELPARAM(point.x, point.y));
  Check(!window.hovered, "移到标题区取消按钮悬停");
  SendMessage(hwnd, WM_NCMOUSEMOVE, HTMAXBUTTON, MAKELPARAM(point.x, point.y));
  SendMessage(hwnd, WM_NCMOUSELEAVE, 0, 0);
  Check(!window.hovered && !window.pressed, "离开原生命中区清除按钮动效");
  Press(hwnd);
  Check(!IsZoomed(hwnd) && GetCapture() == hwnd, "按下仅捕获，不提前最大化");
  Check(window.hovered && window.pressed, "按下同步自绘按压状态");
  SendMessage(hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(200, 200));
  Check(!window.hovered && !window.pressed, "按住拖出取消按钮动效");
  POINT inside = MaxPoint(hwnd);
  SendMessage(hwnd, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(inside.x, inside.y));
  Check(window.hovered && window.pressed, "按住移回恢复按压动效");
  Release(hwnd);
  Check(IsZoomed(hwnd), "按钮内松开最大化一次");
  Check(!window.hovered && !window.pressed && !window.IsFullscreen(),
        "最大化清除旧动效且不进入全屏");
  Check(Corner(hwnd) == 1, "最大化窗口使用直角");
  RECT client{};
  GetClientRect(hwnd, &client);
  POINT origin{0, 0};
  ClientToScreen(hwnd, &origin);
  MONITORINFO monitor{sizeof(MONITORINFO)};
  GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
  RECT maximized_bounds{};
  GetWindowRect(hwnd, &maximized_bounds);
  Check(EqualRect(&maximized_bounds, &monitor.rcWork),
        "最大化外框也限定在工作区，避免被系统判作全屏而隐藏任务栏");
  Check(origin.x == monitor.rcWork.left && origin.y == monitor.rcWork.top &&
        client.right == monitor.rcWork.right - monitor.rcWork.left &&
        client.bottom == monitor.rcWork.bottom - monitor.rcWork.top,
        "最大化客户区恰好覆盖工作区，不遮任务栏");

  Press(hwnd);
  Release(hwnd);
  Check(!IsZoomed(hwnd), "第二次点击还原窗口");
  RECT restored{};
  GetWindowRect(hwnd, &restored);
  Check(EqualRect(&before, &restored), "还原保留原窗口位置与尺寸");
  Check(Corner(hwnd) == 2, "还原重新启用圆角");

  Press(hwnd);
  Release(hwnd, false);
  Check(!IsZoomed(hwnd) && GetCapture() != hwnd, "按下拖出再松开不切换");
  Press(hwnd);
  SendMessage(hwnd, WM_CANCELMODE, 0, 0);
  Release(hwnd);
  Check(!IsZoomed(hwnd), "取消鼠标跟踪后不切换");
  Press(hwnd);
  ReleaseCapture();
  Release(hwnd);
  Check(!IsZoomed(hwnd), "失去鼠标捕获后不切换");

  SetCapture(hwnd);
  SendMessage(hwnd, WM_SIZE, SIZE_RESTORED, 0);
  Check(GetCapture() == hwnd, "尺寸变化不释放其他窗口操作的鼠标捕获");
  window.SetChromeRegions({});
  Check(GetCapture() == hwnd, "命中区域更新不释放其他窗口操作的鼠标捕获");
  ReleaseCapture();
  point = MaxPoint(hwnd);
  ClientToScreen(hwnd, &point);
  Check(window.HitTestChrome(point) == HTCLIENT, "弹窗覆盖时取消最大化命中");
  window.SetChromeRegions({{920, 10, 40, 36, true}});
  Press(hwnd);
  Release(hwnd);
  ShowWindow(hwnd, SW_MINIMIZE);
  Check(IsIconic(hwnd), "最大化后可以最小化");
  ShowWindow(hwnd, SW_RESTORE);
  Pump();
  Check(IsZoomed(hwnd), "从最小化返回保留最大化状态");
  GetWindowRect(hwnd, &maximized_bounds);
  Check(EqualRect(&maximized_bounds, &monitor.rcWork), "最小化恢复仍保留任务栏空间");

  Check(window.SetFullscreen(true), "从最大化进入全屏");
  RECT fullscreen_bounds{};
  GetWindowRect(hwnd, &fullscreen_bounds);
  Check(EqualRect(&fullscreen_bounds, &monitor.rcMonitor), "仅显式全屏覆盖整个显示器");
  Check(Corner(hwnd) == 1, "全屏使用直角");
  Check(window.HitTestChrome(point) == HTCLIENT, "全屏不启用标题按钮");
  Check(window.SetFullscreen(false) && IsZoomed(hwnd), "退出全屏恢复最大化状态");
  GetWindowRect(hwnd, &maximized_bounds);
  Check(EqualRect(&maximized_bounds, &monitor.rcWork), "退出全屏重新避让任务栏");
  ShowWindow(hwnd, SW_RESTORE);
  Check(window.SetFullscreen(true) && window.SetFullscreen(false), "普通窗口全屏往返");
  Check(!IsZoomed(hwnd) && Corner(hwnd) == 2, "全屏返回普通窗口恢复圆角");
  window.Destroy();
  std::cout << "失败数量: " << failures << '\n';
  return failures ? 1 : 0;
}
