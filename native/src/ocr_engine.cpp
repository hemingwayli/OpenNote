#include "opennote_ocr.h"
#include <onnxruntime_cxx_api.h>
#include <windows.h>
#include "opencv_public_paths.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <yaml-cpp/yaml.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Quad = std::array<cv::Point2f, 4>;
struct Cancelled : std::exception {};
struct Character { std::string text; float confidence; Quad quad; };
struct Line { std::string text; float confidence; float detection_confidence; Quad quad; std::vector<Character> characters; };
struct Crop { cv::Mat pixels; cv::Mat image_to_crop; };

Ort::Env make_environment() {
  // 宿主进程可能已加载其他插件的 onnxruntime.dll，使用独立文件名和显式 API 初始化。
  static std::once_flag once;
  std::call_once(once, [] {
    HMODULE own_module=nullptr;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&onocr_abi_version), &own_module)) throw std::runtime_error("Cannot locate OCR native module");
    std::wstring buffer(32768,L'\0');
    auto length=GetModuleFileNameW(own_module,buffer.data(),static_cast<DWORD>(buffer.size()));
    if(!length || length>=buffer.size()) throw std::runtime_error("Cannot locate OCR dependency directory");
    buffer.resize(length);
    auto library=std::filesystem::path(buffer).parent_path() / L"opennote_onnxruntime.dll";
    auto module=LoadLibraryExW(library.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if(!module) throw std::runtime_error("Cannot load bundled opennote_onnxruntime.dll (Windows error " + std::to_string(GetLastError()) + ")");
    using ApiBaseFunction=const OrtApiBase* (ORT_API_CALL*)();
    auto getter=reinterpret_cast<ApiBaseFunction>(GetProcAddress(module,"OrtGetApiBase"));
    if(!getter) throw std::runtime_error("Bundled ONNX Runtime is missing OrtGetApiBase");
    if(std::strcmp(getter()->GetVersionString(),"1.21.0")!=0) throw std::runtime_error("Bundled ONNX Runtime version is not the pinned 1.21.0");
    const auto* api=getter()->GetApi(ORT_API_VERSION);
    if(!api) throw std::runtime_error("Bundled ONNX Runtime API version does not match OCR module");
    Ort::InitApi(api);
    // API 函数指针供全部 Engine 使用，运行库保留到进程退出。
  });
  return Ort::Env(ORT_LOGGING_LEVEL_WARNING,"OpenNoteOCR");
}

std::string read_utf8(const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) throw std::runtime_error("Cannot read model configuration: " + path.u8string());
  return std::string(std::istreambuf_iterator<char>(file), {});
}
char* allocate_string(const std::string& value) {
  auto* memory = static_cast<char*>(std::malloc(value.size() + 1));
  if (!memory) throw std::bad_alloc();
  std::memcpy(memory, value.c_str(), value.size() + 1);
  return memory;
}
void report_error(char** target, const std::string& value) noexcept {
  if (!target) return;
  try { *target = allocate_string(value); } catch (...) { *target = nullptr; }
}
std::string escaped(const std::string& value) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : value) {
    switch(c) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (c < 32) out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c) << std::dec;
        else out << c;
    }
  }
  out << '"';
  return out.str();
}
void emit_quad(std::ostream& out, const Quad& quad) {
  out << '[';
  for (size_t i = 0; i < quad.size(); ++i) {
    if (i) out << ',';
    out << '[' << quad[i].x << ',' << quad[i].y << ']';
  }
  out << ']';
}
// 与 PP-OCR 的矩形框顺序一致：左上、右上、右下、左下。
Quad ordered_box(const cv::RotatedRect& rect) {
  cv::Point2f points[4];
  rect.points(points);
  std::sort(points, points + 4, [](auto a, auto b) { return a.x < b.x || (a.x == b.x && a.y < b.y); });
  auto left_top = points[0].y < points[1].y ? points[0] : points[1];
  auto left_bottom = points[0].y < points[1].y ? points[1] : points[0];
  auto right_top = points[2].y < points[3].y ? points[2] : points[3];
  auto right_bottom = points[2].y < points[3].y ? points[3] : points[2];
  return {left_top, right_top, right_bottom, left_bottom};
}
float distance(cv::Point2f a, cv::Point2f b) { return static_cast<float>(cv::norm(a - b)); }
cv::Point2f project(const cv::Mat& transform, float x, float y) {
  double w = transform.at<double>(2, 0) * x + transform.at<double>(2, 1) * y + transform.at<double>(2, 2);
  return {static_cast<float>((transform.at<double>(0, 0)*x + transform.at<double>(0, 1)*y + transform.at<double>(0, 2))/w),
          static_cast<float>((transform.at<double>(1, 0)*x + transform.at<double>(1, 1)*y + transform.at<double>(1, 2))/w)};
}
Crop make_crop(const cv::Mat& image, const Quad& quad) {
  int width = std::max(2, static_cast<int>(std::round(std::max(distance(quad[0],quad[1]), distance(quad[3],quad[2])))));
  int height = std::max(2, static_cast<int>(std::round(std::max(distance(quad[0],quad[3]), distance(quad[1],quad[2])))));
  Quad dest = {cv::Point2f(0,0), cv::Point2f(static_cast<float>(width-1),0),
               cv::Point2f(static_cast<float>(width-1),static_cast<float>(height-1)), cv::Point2f(0,static_cast<float>(height-1))};
  auto transform = cv::getPerspectiveTransform(quad.data(), dest.data());
  cv::Mat crop;
  cv::warpPerspective(image, crop, transform, cv::Size(width,height), cv::INTER_CUBIC, cv::BORDER_REPLICATE);
  if (height >= width * 1.5) {
    cv::rotate(crop,crop,cv::ROTATE_90_COUNTERCLOCKWISE);
    cv::Mat rotation = (cv::Mat_<double>(3,3) << 0,1,0, -1,0,width-1, 0,0,1);
    transform = rotation * transform;
  }
  return {crop,transform};
}

struct ReadingDirection {
  bool vertical = false;
  int vertical_votes = 0, horizontal_votes = 0;
  int header_lines = 0;
  double vertical_area_fraction = 0;
};
ReadingDirection arrange_lines(std::vector<Line>& lines, int page_width, int page_height) {
  ReadingDirection result;
  double total_area = 0, vertical_area = 0;
  for(const auto& line:lines) {
    const auto width=std::max(distance(line.quad[0],line.quad[1]),distance(line.quad[3],line.quad[2]));
    const auto height=std::max(distance(line.quad[0],line.quad[3]),distance(line.quad[1],line.quad[2]));
    const auto area=static_cast<double>(width)*height;
    total_area+=area;
    // 单个字、短双行注释和竖向页眉不能单独把普通横排书判成竖排。
    if(height>=3*width && height>=std::max(48.f,page_height*.06f)) {
      ++result.vertical_votes; vertical_area+=area;
    } else if(width>=3*height && width>=std::max(48.f,page_width*.06f)) {
      ++result.horizontal_votes;
    }
  }
  result.vertical_area_fraction=total_area>0 ? vertical_area/total_area : 0;
  result.vertical=result.vertical_votes>=3 &&
      result.vertical_votes>=2*result.horizontal_votes && result.vertical_area_fraction>=.65;
  auto center_x=[](const Line& line) { return (line.quad[0].x+line.quad[1].x+line.quad[2].x+line.quad[3].x)/4; };
  std::stable_sort(lines.begin(),lines.end(),[&](const auto& a,const auto& b) {
    if(result.vertical) {
      const auto ax=center_x(a), bx=center_x(b);
      return ax>bx || (ax==bx && a.quad[0].y<b.quad[0].y);
    }
    return a.quad[0].y<b.quad[0].y || (a.quad[0].y==b.quad[0].y && a.quad[0].x<b.quad[0].x);
  });
  // 只修正同一行/列内的小幅框偏移，不改变页面四边形，也不重建复杂版面。
  for(size_t i=1;i<lines.size();++i) {
    size_t j=i;
    while(j>0) {
      const auto& before=lines[j-1]; const auto& after=lines[j];
      const float tolerance=.45f*std::min(
          distance(before.quad[0],before.quad[result.vertical?1:3]),
          distance(after.quad[0],after.quad[result.vertical?1:3]));
      if(result.vertical) {
        if(std::abs(center_x(before)-center_x(after))>tolerance || before.quad[0].y<=after.quad[0].y) break;
      } else if(std::abs(before.quad[0].y-after.quad[0].y)>tolerance || before.quad[0].x<=after.quad[0].x) break;
      std::swap(lines[j-1],lines[j]); --j;
    }
  }
  if(result.vertical) {
    float body_top=static_cast<float>(page_height);
    for(const auto& line:lines) {
      const auto width=distance(line.quad[0],line.quad[1]);
      const auto height=distance(line.quad[0],line.quad[3]);
      if(height>=6*width && height>=page_height*.35f)
        body_top=std::min(body_top,std::min(line.quad[0].y,line.quad[1].y));
    }
    if(body_top<page_height) {
      // 完全位于长正文列上方的页眉先输出，避免摘录跨正文列时夹入页眉。
      auto divider=std::stable_partition(lines.begin(),lines.end(),[&](const Line& line) {
        return std::max({line.quad[0].y,line.quad[1].y,line.quad[2].y,line.quad[3].y})<body_top;
      });
      result.header_lines=static_cast<int>(std::distance(lines.begin(),divider));
    }
  }
  return result;
}

struct Engine {
  Ort::Env env{make_environment()};
  std::unique_ptr<Ort::Session> det;
  std::unique_ptr<Ort::Session> rec;
  Ort::MemoryInfo memory{Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault)};
  std::string det_input, det_output, rec_input, rec_output;
  std::vector<std::string> dictionary;
  std::atomic<bool> cancelled{false};
  std::mutex operation_mutex;
  std::mutex run_mutex;
  Ort::RunOptions* active_run = nullptr;
  float threshold = .2f, box_threshold = .45f, unclip_ratio = 1.4f;
  int max_candidates = 3000, rec_height = 48, rec_base_width = 320;
  bool det_rgb = false, rec_rgb = false;
  std::array<float,3> mean{.485f,.456f,.406f}, stddev{.229f,.224f,.225f};
  std::string model = "PP-OCRv6_small";

  Engine(const std::filesystem::path& root, int threads) {
    cv::setNumThreads(1);
    auto det_config = YAML::Load(read_utf8(root / "det" / "inference.yml"));
    auto rec_config = YAML::Load(read_utf8(root / "rec" / "inference.yml"));
    if (det_config["Global"]["model_name"].as<std::string>() != "PP-OCRv6_small_det" ||
        rec_config["Global"]["model_name"].as<std::string>() != "PP-OCRv6_small_rec")
      throw std::runtime_error("The installed OCR model package is not PP-OCRv6_small");
    const auto post = det_config["PostProcess"];
    if (post["name"].as<std::string>() != "DBPostProcess" || rec_config["PostProcess"]["name"].as<std::string>() != "CTCLabelDecode")
      throw std::runtime_error("Unsupported OCR model postprocessing");
    threshold = post["thresh"].as<float>();
    box_threshold = post["box_thresh"].as<float>();
    unclip_ratio = post["unclip_ratio"].as<float>();
    max_candidates = post["max_candidates"].as<int>();
    for (const auto& op : det_config["PreProcess"]["transform_ops"]) {
      if (op["DecodeImage"]) det_rgb = op["DecodeImage"]["img_mode"].as<std::string>() == "RGB";
      if (op["NormalizeImage"]) {
        for (int i=0;i<3;++i) { mean[i] = op["NormalizeImage"]["mean"][i].as<float>(); stddev[i] = op["NormalizeImage"]["std"][i].as<float>(); }
      }
    }
    for (const auto& op : rec_config["PreProcess"]["transform_ops"]) {
      if (op["DecodeImage"]) rec_rgb = op["DecodeImage"]["img_mode"].as<std::string>() == "RGB";
      if (op["RecResizeImg"]) {
        rec_height = op["RecResizeImg"]["image_shape"][1].as<int>();
        rec_base_width = op["RecResizeImg"]["image_shape"][2].as<int>();
      }
    }
    dictionary = rec_config["PostProcess"]["character_dict"].as<std::vector<std::string>>();
    if (dictionary.empty()) throw std::runtime_error("OCR character dictionary is empty");
    // Paddle CTCLabelDecode 在原字典末尾添加空格，索引 0 是 blank。
    if (std::find(dictionary.begin(),dictionary.end()," ") == dictionary.end()) dictionary.emplace_back(" ");
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(std::clamp(threads,1,8));
    options.SetInterOpNumThreads(1);
    options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    det = std::make_unique<Ort::Session>(env,(root / "det" / "inference.onnx").c_str(),options);
    rec = std::make_unique<Ort::Session>(env,(root / "rec" / "inference.onnx").c_str(),options);
    Ort::AllocatorWithDefaultOptions allocator;
    if (det->GetInputCount()!=1 || rec->GetInputCount()!=1 || det->GetOutputCount()!=1 || rec->GetOutputCount()!=1)
      throw std::runtime_error("Unexpected OCR model input/output count");
    det_input = det->GetInputNameAllocated(0,allocator).get(); det_output = det->GetOutputNameAllocated(0,allocator).get();
    rec_input = rec->GetInputNameAllocated(0,allocator).get(); rec_output = rec->GetOutputNameAllocated(0,allocator).get();
  }
  void check_cancel() const { if (cancelled.load()) throw Cancelled(); }
  void cancel() {
    cancelled.store(true);
    std::lock_guard<std::mutex> lock(run_mutex);
    if (active_run) active_run->SetTerminate();
  }
  std::vector<Ort::Value> run(Ort::Session& session, std::vector<float>& data, const std::array<int64_t,4>& shape,
                             const std::string& input, const std::string& output) {
    check_cancel();
    Ort::RunOptions run_options;
    {
      std::lock_guard<std::mutex> lock(run_mutex);
      if (cancelled.load()) throw Cancelled();
      active_run = &run_options;
    }
    const char* input_name = input.c_str(); const char* output_name = output.c_str();
    try {
      auto tensor = Ort::Value::CreateTensor<float>(memory,data.data(),data.size(),shape.data(),shape.size());
      auto outputs = session.Run(run_options,&input_name,&tensor,1,&output_name,1);
      { std::lock_guard<std::mutex> lock(run_mutex); active_run = nullptr; }
      check_cancel();
      return outputs;
    } catch (...) {
      { std::lock_guard<std::mutex> lock(run_mutex); active_run = nullptr; }
      check_cancel();
      throw;
    }
  }
  std::vector<Line> detect(const cv::Mat& source) {
    // 首版限制检测长边，识别裁片仍使用输入原分辨率；页面队列由 Dart 管理。
    const double ratio = std::min(1.,1536. / std::max(source.cols,source.rows));
    const int width = std::max(32,static_cast<int>(std::round(source.cols*ratio/32.))*32);
    const int height = std::max(32,static_cast<int>(std::round(source.rows*ratio/32.))*32);
    cv::Mat resized;
    cv::resize(source,resized,cv::Size(width,height),0,0,cv::INTER_LINEAR);
    if (det_rgb) cv::cvtColor(resized,resized,cv::COLOR_BGR2RGB);
    const size_t plane = static_cast<size_t>(width)*height;
    std::vector<float> data(plane*3);
    for (int y=0;y<height;++y) {
      const auto* row=resized.ptr<cv::Vec3b>(y);
      for(int x=0;x<width;++x) for(int c=0;c<3;++c)
        data[c*plane+static_cast<size_t>(y)*width+x]=(row[x][c]/255.f-mean[c])/stddev[c];
    }
    auto output = run(*det,data,{1,3,height,width},det_input,det_output);
    auto info=output[0].GetTensorTypeAndShapeInfo(); auto shape=info.GetShape();
    if(shape.size()!=4 || shape[0]!=1 || shape[1]!=1 || info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
      throw std::runtime_error("Unexpected detection output tensor");
    const int map_height=static_cast<int>(shape[2]),map_width=static_cast<int>(shape[3]);
    cv::Mat probability(map_height,map_width,CV_32F,output[0].GetTensorMutableData<float>());
    cv::Mat bitmap;
    cv::compare(probability,threshold,bitmap,cv::CMP_GT);
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(bitmap,contours,cv::RETR_LIST,cv::CHAIN_APPROX_SIMPLE);
    std::vector<Line> lines;
    for(size_t i=0;i<std::min(contours.size(),static_cast<size_t>(max_candidates));++i) {
      check_cancel();
      if(contours[i].size()<3) continue;
      auto rect=cv::minAreaRect(contours[i]);
      if(std::min(rect.size.width,rect.size.height)<3) continue;
      auto box=ordered_box(rect);
      std::vector<cv::Point> polygon;
      for(const auto& p:box) polygon.emplace_back(static_cast<int>(std::round(p.x)),static_cast<int>(std::round(p.y)));
      auto roi=cv::boundingRect(polygon) & cv::Rect(0,0,map_width,map_height);
      if(roi.empty()) continue;
      cv::Mat mask(roi.height,roi.width,CV_8U,cv::Scalar(0));
      for(auto& p:polygon) p-=roi.tl();
      cv::fillConvexPoly(mask,polygon,cv::Scalar(255));
      const float score=static_cast<float>(cv::mean(probability(roi),mask)[0]);
      if(score<box_threshold) continue;
      // DB 对矩形框做 area * unclip_ratio / perimeter 外扩；其外扩后的最小矩形等价于边长增加 2d。
      const float perimeter=2*(rect.size.width+rect.size.height);
      const float offset=rect.size.area()*unclip_ratio/perimeter;
      rect.size.width+=2*offset; rect.size.height+=2*offset;
      if(std::min(rect.size.width,rect.size.height)<5) continue;
      box=ordered_box(rect);
      for(auto& p:box) {
        p.x=std::clamp(p.x*source.cols/map_width,0.f,static_cast<float>(source.cols-1));
        p.y=std::clamp(p.y*source.rows/map_height,0.f,static_cast<float>(source.rows-1));
      }
      lines.push_back({"",0,score,box,{}});
    }
    return lines;
  }
  void recognize_line(const cv::Mat& source, Line& line) {
    auto crop=make_crop(source,line.quad);
    double aspect=static_cast<double>(crop.pixels.cols)/crop.pixels.rows;
    int padded_width=std::clamp(std::max(rec_base_width,static_cast<int>(std::ceil(rec_height*aspect))),rec_base_width,3200);
    int resized_width=std::clamp(static_cast<int>(std::ceil(rec_height*aspect)),1,padded_width);
    cv::Mat resized;
    cv::resize(crop.pixels,resized,cv::Size(resized_width,rec_height),0,0,cv::INTER_LINEAR);
    if(rec_rgb) cv::cvtColor(resized,resized,cv::COLOR_BGR2RGB);
    size_t plane=static_cast<size_t>(rec_height)*padded_width;
    std::vector<float> data(plane*3,0);
    for(int y=0;y<rec_height;++y) {
      auto* row=resized.ptr<cv::Vec3b>(y);
      for(int x=0;x<resized_width;++x) for(int c=0;c<3;++c)
        data[c*plane+static_cast<size_t>(y)*padded_width+x]=row[x][c]/127.5f-1;
    }
    auto output=run(*rec,data,{1,3,rec_height,padded_width},rec_input,rec_output);
    auto info=output[0].GetTensorTypeAndShapeInfo(); auto shape=info.GetShape();
    if(shape.size()!=3 || shape[0]!=1 || shape[2]!=static_cast<int64_t>(dictionary.size()+1) || info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
      throw std::runtime_error("Recognition output does not match installed CTC dictionary");
    auto* probs=output[0].GetTensorData<float>();
    int steps=static_cast<int>(shape[1]),classes=static_cast<int>(shape[2]);
    struct Token { int symbol,begin,end; float confidence; };
    std::vector<Token> tokens;
    int previous=-1;
    for(int t=0;t<steps;++t) {
      const float* row=probs+static_cast<size_t>(t)*classes;
      int symbol=static_cast<int>(std::max_element(row,row+classes)-row);
      if(symbol!=0 && symbol!=previous) tokens.push_back({symbol,t,t+1,row[symbol]});
      else if(symbol!=0 && !tokens.empty()) { tokens.back().end=t+1; tokens.back().confidence=std::max(tokens.back().confidence,row[symbol]); }
      previous=symbol;
    }
    cv::Mat inverse=crop.image_to_crop.inv();
    const float valid_steps=steps*static_cast<float>(resized_width)/padded_width;
    float sum=0;
    for(size_t i=0;i<tokens.size();++i) {
      const auto& token=tokens[i];
      // CTC 时间步只能提供近似字符定位；边界按相邻 token 中心细分，明确记录精度。
      float begin=i==0 ? 0.f : (tokens[i-1].end+token.begin)/2.f;
      float end=i+1==tokens.size() ? valid_steps : (token.end+tokens[i+1].begin)/2.f;
      float x0=std::clamp(begin/valid_steps,0.f,1.f)*(crop.pixels.cols-1);
      float x1=std::clamp(end/valid_steps,0.f,1.f)*(crop.pixels.cols-1);
      if(x1<=x0) continue;
      Quad quad={project(inverse,x0,0),project(inverse,x1,0),project(inverse,x1,static_cast<float>(crop.pixels.rows-1)),project(inverse,x0,static_cast<float>(crop.pixels.rows-1))};
      const auto& text=dictionary.at(token.symbol-1);
      line.text+=text; sum+=token.confidence;
      line.characters.push_back({text,token.confidence,quad});
    }
    line.confidence=line.characters.empty()?0:sum/line.characters.size();
  }
  std::string recognize(const uint8_t* pixels,int width,int height,int stride) {
    std::unique_lock<std::mutex> lock(operation_mutex,std::try_to_lock);
    if(!lock.owns_lock()) throw std::runtime_error("OCR engine is already recognizing an image");
    cancelled.store(false);
    const auto start=std::chrono::steady_clock::now();
    cv::Mat rgba(height,width,CV_8UC4,const_cast<uint8_t*>(pixels),static_cast<size_t>(stride));
    // RGBA 透明像素先合成到白底，避免透明页面被当作黑页。
    cv::Mat source(height,width,CV_8UC3);
    for(int y=0;y<height;++y) {
      const auto* row=rgba.ptr<cv::Vec4b>(y); auto* dest=source.ptr<cv::Vec3b>(y);
      for(int x=0;x<width;++x) {
        int alpha=row[x][3];
        for(int c=0;c<3;++c) dest[x][c]=static_cast<uint8_t>((row[x][2-c]*alpha+255*(255-alpha)+127)/255);
      }
    }
    check_cancel();
    auto lines=detect(source);
    for(auto& line:lines) { check_cancel(); recognize_line(source,line); }
    lines.erase(std::remove_if(lines.begin(),lines.end(),[](const Line& line) { return line.text.empty() || line.confidence<.3f; }),lines.end());
    const auto direction=arrange_lines(lines,width,height);
    check_cancel();
    auto elapsed=std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now()-start).count();
    std::ostringstream out; out.imbue(std::locale::classic()); out << std::fixed << std::setprecision(4);
    out << "{\"formatVersion\":1,\"engine\":\"onnxruntime-cpu\",\"model\":\"PP-OCRv6_small\",\"width\":" << width << ",\"height\":" << height
        << ",\"elapsedMs\":" << elapsed << ",\"coordinateSpace\":\"inputImagePixelsTopLeft\",\"readingOrder\":"
        << escaped(direction.vertical?"basicVerticalColumns":"basicRows") << ",\"writingDirection\":"
        << escaped(direction.vertical?"verticalRtl":"horizontalLtr")
        << ",\"directionDetection\":{\"method\":\"dominantElongatedBoxes\",\"verticalVotes\":" << direction.vertical_votes
        << ",\"horizontalVotes\":" << direction.horizontal_votes << ",\"verticalAreaFraction\":" << direction.vertical_area_fraction
        << ",\"headerLines\":" << direction.header_lines << "},\"lines\":[";
    size_t index=0;
    for(const auto& line:lines) {
      if(line.text.empty() || line.confidence<.3f) continue;
      if(index) out << ',';
      out << "{\"order\":" << index++ << ",\"text\":" << escaped(line.text) << ",\"confidence\":" << line.confidence
          << ",\"detectionConfidence\":" << line.detection_confidence << ",\"precision\":\"detectedLine\",\"quad\":";
      emit_quad(out,line.quad); out << ",\"characters\":[";
      for(size_t c=0;c<line.characters.size();++c) {
        const auto& character=line.characters[c]; if(c) out << ',';
        out << "{\"text\":" << escaped(character.text) << ",\"confidence\":" << character.confidence << ",\"precision\":\"approximateCtcAlignment\",\"quad\":";
        emit_quad(out,character.quad); out << '}';
      }
      out << "]}";
    }
    out << "]}";
    return out.str();
  }
};
}

extern "C" {
int32_t onocr_abi_version() { return 1; }
int32_t onocr_create(const char* model_directory,int32_t threads,void** engine,char** error) {
  if(error) *error=nullptr;
  if(engine) *engine=nullptr;
  if(!engine || !model_directory || !*model_directory || threads<1 || threads>8) { report_error(error,"Invalid OCR creation arguments"); return 2; }
  try { *engine=new Engine(std::filesystem::u8path(model_directory),threads); return 0; }
  catch(const std::exception& ex) { report_error(error,ex.what()); return 3; }
  catch(...) { report_error(error,"Unknown OCR initialization failure"); return 3; }
}
int32_t onocr_recognize(void* engine,const uint8_t* rgba,size_t byte_length,int32_t width,int32_t height,int32_t stride,char** result,char** error) {
  if(result) *result=nullptr;
  if(error) *error=nullptr;
  if(!engine || !rgba || !result || width<1 || height<1 || width>16384 || height>16384 || static_cast<int64_t>(stride)<static_cast<int64_t>(width)*4 ||
      byte_length<static_cast<uint64_t>(stride)*(height-1)+static_cast<uint64_t>(width)*4 || static_cast<uint64_t>(width)*height>100000000) {
    report_error(error,"Invalid RGBA dimensions, stride or buffer length"); return 2;
  }
  try { *result=allocate_string(static_cast<Engine*>(engine)->recognize(rgba,width,height,stride)); return 0; }
  catch(const Cancelled&) { report_error(error,"OCR cancelled"); return 1; }
  catch(const std::exception& ex) { report_error(error,ex.what()); return 3; }
  catch(...) { report_error(error,"Unknown OCR inference failure"); return 3; }
}
void onocr_cancel(void* engine) { if(engine) { try { static_cast<Engine*>(engine)->cancel(); } catch(...) {} } }
void onocr_free(void* allocation) { std::free(allocation); }
void onocr_destroy(void* engine) { delete static_cast<Engine*>(engine); }
}
