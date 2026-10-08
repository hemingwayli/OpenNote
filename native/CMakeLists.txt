cmake_minimum_required(VERSION 3.20)
project(opennote_ocr LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "首版原生依赖包目前只提供 Windows x64")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(OPENNOTE_OCR_DEPENDENCIES "${CMAKE_CURRENT_SOURCE_DIR}/third_party" CACHE PATH "OCR 原生依赖根目录")
set(OPENNOTE_ORT_ROOT "${OPENNOTE_OCR_DEPENDENCIES}/onnxruntime")
set(OpenCV_DIR "${OPENNOTE_OCR_DEPENDENCIES}/opencv/build/x64/vc16/lib")
find_package(OpenCV 4.11 REQUIRED COMPONENTS core imgproc imgcodecs)
# OpenCV 的导入目标在本目录创建；父目录安装表达式也需要解析其运行库路径。
set_property(TARGET opencv_world PROPERTY IMPORTED_GLOBAL TRUE)
# Flutter 的 Profile 使用优化编译，需明确映射到供应商提供的 Release 导入库。
set_target_properties(opencv_world opencv_core opencv_imgproc opencv_imgcodecs
  PROPERTIES MAP_IMPORTED_CONFIG_PROFILE Release)
set(YAML_CPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(YAML_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_INSTALL OFF CACHE BOOL "" FORCE)
if(CMAKE_VERSION VERSION_GREATER_EQUAL "4.0")
  set(CMAKE_POLICY_VERSION_MINIMUM 3.5)
endif()
add_subdirectory("${OPENNOTE_OCR_DEPENDENCIES}/yaml-cpp-0.8.0" "${CMAKE_CURRENT_BINARY_DIR}/yaml-cpp")
configure_file("${OPENNOTE_ORT_ROOT}/lib/onnxruntime.dll" "${OPENNOTE_ORT_ROOT}/lib/opennote_onnxruntime.dll" COPYONLY)
add_library(opennote_ort INTERFACE)
target_include_directories(opennote_ort INTERFACE "${OPENNOTE_ORT_ROOT}/include")
add_library(opennote_ocr SHARED src/ocr_engine.cpp)
target_include_directories(opennote_ocr PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(opennote_ocr PRIVATE opennote_ort yaml-cpp::yaml-cpp ${OpenCV_LIBS})
target_compile_definitions(opennote_ocr PRIVATE OPENNOTE_OCR_EXPORTS ORT_API_MANUAL_INIT NOMINMAX WIN32_LEAN_AND_MEAN)
target_compile_options(opennote_ocr PRIVATE /utf-8 /W4 /EHsc)
set(OPENNOTE_OCR_RUNTIME
  "$<TARGET_FILE:opennote_ocr>"
  "${OPENNOTE_ORT_ROOT}/lib/opennote_onnxruntime.dll"
  "$<TARGET_FILE:opencv_world>")
set(OPENNOTE_OCR_MODEL_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../assets/ocr/models/PP-OCRv6_small")
if(NOT CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
  set(OPENNOTE_OCR_BUNDLED_LIBRARIES "${OPENNOTE_OCR_RUNTIME}" PARENT_SCOPE)
  set(OPENNOTE_OCR_MODEL_DIRECTORY "${OPENNOTE_OCR_MODEL_DIRECTORY}" PARENT_SCOPE)
endif()

option(OPENNOTE_OCR_BUILD_CLI "构建原生 OCR 验证 CLI" OFF)
if(OPENNOTE_OCR_BUILD_CLI)
  add_executable(opennote_ocr_cli src/ocr_cli.cpp)
  target_link_libraries(opennote_ocr_cli PRIVATE opennote_ocr yaml-cpp::yaml-cpp ${OpenCV_LIBS})
  target_compile_options(opennote_ocr_cli PRIVATE /utf-8 /W4 /EHsc)
  target_compile_definitions(opennote_ocr_cli PRIVATE NOMINMAX)
  add_custom_command(TARGET opennote_ocr_cli POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${OPENNOTE_ORT_ROOT}/lib/opennote_onnxruntime.dll"
      "$<TARGET_FILE:opencv_world>"
      "$<TARGET_FILE_DIR:opennote_ocr_cli>")
endif()
