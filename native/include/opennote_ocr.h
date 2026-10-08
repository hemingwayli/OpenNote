#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef _WIN32
#ifdef OPENNOTE_OCR_EXPORTS
#define ONOCR_API __declspec(dllexport)
#else
#define ONOCR_API __declspec(dllimport)
#endif
#else
#define ONOCR_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif

// 返回值：0 成功，1 已取消，2 参数错误，3 引擎错误。字符串为 UTF-8，由本库释放。
ONOCR_API int32_t onocr_create(const char* model_directory_utf8, int32_t cpu_threads,
                              void** engine, char** error_utf8);
// 输入图像为 RGBA8888，stride 以字节计；输出四边形坐标属于输入图像，不属于 PDF。
ONOCR_API int32_t onocr_recognize(void* engine, const uint8_t* rgba, size_t byte_length,
                                 int32_t width, int32_t height, int32_t stride,
                                 char** result_json_utf8, char** error_utf8);
// cancel 可从另一线程调用；destroy 只能在识别调用结束后调用。
ONOCR_API void onocr_cancel(void* engine);
ONOCR_API void onocr_free(void* allocation);
ONOCR_API void onocr_destroy(void* engine);
ONOCR_API int32_t onocr_abi_version(void);
#ifdef __cplusplus
}
#endif
