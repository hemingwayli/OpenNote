#pragma once

#include <opencv2/core/base.hpp>

#ifdef NDEBUG
#include <array>
#include <cstddef>

namespace opennote {
// 在编译期复制文件名，避免仅偏移指针时仍把完整路径留在 DLL 字符串中。
template <std::size_t N>
constexpr std::array<char, N> public_source_name(const char (&path)[N]) {
  std::size_t start = 0;
  for (std::size_t i = 0; i < N - 1; ++i) {
    if (path[i] == '/' || path[i] == '\\') start = i + 1;
  }
  std::array<char, N> name{};
  for (std::size_t i = start; i < N; ++i) name[i - start] = path[i];
  return name;
}
}  // namespace opennote

// 保留 OpenCV 的条件、异常码、表达式、函数和行号，仅公开源文件名。
#define OPENNOTE_CV_FILE ([]() noexcept -> const char* { \
  static constexpr auto name = opennote::public_source_name(__FILE__); \
  return name.data(); \
}())

#undef CV_Error
#define CV_Error(code, msg) cv::error(code, msg, CV_Func, OPENNOTE_CV_FILE, __LINE__)
#undef CV_Error_
#define CV_Error_(code, args) cv::error(code, cv::format args, CV_Func, OPENNOTE_CV_FILE, __LINE__)
#undef CV_Assert
#define CV_Assert(expr) do { if (!!(expr)) ; else cv::error(cv::Error::StsAssert, #expr, CV_Func, OPENNOTE_CV_FILE, __LINE__); } while (0)
#undef CV_AssertTerminate
#define CV_AssertTerminate(expr) do { if (!!(expr)) ; else cv::terminate(#expr, CV_Func, OPENNOTE_CV_FILE, __LINE__); } while (0)
#endif
