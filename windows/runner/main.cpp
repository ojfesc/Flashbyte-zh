#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 单实例互斥体名称。进程存活期间一直持有；同名互斥体已存在说明已有实例。
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\Flashbyte.SingleInstance";

// 主窗口的类名和标题，必须与 win32_window.cpp 注册的类名、
// 下方 Create 调用传入的标题保持一致。
constexpr wchar_t kMainWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kMainWindowTitle[] = L"Flashbyte";

// 把已运行实例的主窗口从最小化或后台状态恢复到最前。
void ActivateExistingWindow() {
  HWND window = nullptr;

  // 首次启动在 Flutter 首帧前会保持窗口隐藏；这里等待窗口真正可见，
  // 避免第二次启动把尚未渲染完成的空窗口提前显示出来。
  for (int attempt = 0; attempt < 50; ++attempt) {
    window = ::FindWindowW(kMainWindowClassName, kMainWindowTitle);
    if (window != nullptr && ::IsWindowVisible(window)) {
      break;
    }
    ::Sleep(100);
  }

  if (window == nullptr) {
    return;
  }

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }

  // 先临时置顶再取消置顶，绕过 Windows 对后台进程抢前台焦点的限制，
  // 保证窗口回到所有普通窗口之上。
  ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetForegroundWindow(window);
  ::BringWindowToTop(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 已有实例运行时不再创建新窗口，只激活已有窗口后退出。
  ::SetLastError(ERROR_SUCCESS);
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow();
    ::CloseHandle(single_instance_mutex);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Flashbyte", origin, size)) {
    ::CoUninitialize();
    if (single_instance_mutex != nullptr) {
      ::ReleaseMutex(single_instance_mutex);
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
