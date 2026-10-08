#include "opennote_ocr.h"
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <yaml-cpp/yaml.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

int wmain(int argc,wchar_t** argv) {
  if(argc!=4) { std::cerr << "Usage: opennote_ocr_cli MODEL_DIRECTORY IMAGE_PATH OUTPUT_JSON\n"; return 2; }
  if(std::wstring(argv[1]) == L"--dictionary") {
    try {
      std::ifstream source(std::filesystem::path(argv[2]) / "rec" / "inference.yml",std::ios::binary);
      if(!source) throw std::runtime_error("Cannot read dictionary YAML");
      std::string yaml((std::istreambuf_iterator<char>(source)),{});
      auto dictionary=YAML::Load(yaml)["PostProcess"]["character_dict"].as<std::vector<std::string>>();
      if(std::find(dictionary.begin(),dictionary.end()," ")==dictionary.end()) dictionary.emplace_back(" ");
      std::ofstream output(std::filesystem::path(argv[3]),std::ios::binary);
      if(!output) throw std::runtime_error("Cannot write dictionary file");
      for(const auto& character:dictionary) {
        if(character.find_first_of("\r\n")!=std::string::npos) throw std::runtime_error("Dictionary contains multiline token");
        output << character << '\n';
      }
      std::cout << "Dictionary characters: " << dictionary.size() << '\n'; return 0;
    } catch(const std::exception& error) { std::cerr << error.what() << '\n'; return 3; }
  }
  void* engine=nullptr; char* error=nullptr;
  auto model=std::filesystem::path(argv[1]).u8string();
  auto status=onocr_create(model.c_str(),2,&engine,&error);
  if(status) { std::cerr << (error?error:"create failed") << '\n'; onocr_free(error); return status; }
  std::ifstream file(std::filesystem::path(argv[2]),std::ios::binary);
  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(file)),{});
  auto image=cv::imdecode(bytes,cv::IMREAD_COLOR);
  if(image.empty()) { std::cerr << "Cannot decode image\n"; onocr_destroy(engine); return 2; }
  cv::Mat rgba; cv::cvtColor(image,rgba,cv::COLOR_BGR2RGBA);
  char* result=nullptr;
  status=onocr_recognize(engine,rgba.data,rgba.total()*rgba.elemSize(),rgba.cols,rgba.rows,static_cast<int32_t>(rgba.step),&result,&error);
  if(status) std::cerr << (error?error:"recognize failed") << '\n';
  else { std::ofstream output(std::filesystem::path(argv[3]),std::ios::binary); output << result; std::cout << "OCR JSON written\n"; }
  onocr_free(result); onocr_free(error); onocr_destroy(engine);
  return status;
}
