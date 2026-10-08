cmake_minimum_required(VERSION 3.14)
project(opennote_window_chrome_test LANGUAGES CXX)

get_filename_component(OPENNOTE_ROOT "../.." ABSOLUTE)
set(OPENNOTE_RUNNER_DIR "${OPENNOTE_ROOT}/windows/runner" CACHE PATH "被验证的窗口源码")
set(FLUTTER_EPHEMERAL "${OPENNOTE_ROOT}/windows/flutter/ephemeral")

add_executable(window_chrome_test
  "window_chrome_test.cpp"
  "${OPENNOTE_RUNNER_DIR}/win32_window.cpp"
)
target_compile_features(window_chrome_test PRIVATE cxx_std_17)
target_compile_definitions(window_chrome_test PRIVATE UNICODE _UNICODE NOMINMAX)
target_compile_options(window_chrome_test PRIVATE /utf-8 /W4)
target_include_directories(window_chrome_test PRIVATE "${OPENNOTE_RUNNER_DIR}" "${FLUTTER_EPHEMERAL}")
target_link_libraries(window_chrome_test PRIVATE
  "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib" dwmapi user32 advapi32
)
enable_testing()
add_test(NAME window_chrome COMMAND window_chrome_test)
set_tests_properties(window_chrome PROPERTIES TIMEOUT 20)
