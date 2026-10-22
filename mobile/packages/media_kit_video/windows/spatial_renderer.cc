// Immuch360: the Spatial 2.5D passes in renderer C (IMMUCH360-NOTE.md, patch
// 11); see the header. The functions follow SpatialRenderer.kt of the phones,
// in its order and with its names where they fit.

// Windows.h, which the EGL headers include, would otherwise define min and max
// as macros over std::min and std::max
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "spatial_renderer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>

#include "projection_shaders.h"
#include "spatial_shaders.h"

namespace {

// OpenGL ES 3.0 values the ES 2.0 headers of the libs package do not have
constexpr GLenum kRgba8 = 0x8058;
constexpr GLenum kRgba16f = 0x881A;
constexpr GLenum kHalfFloat = 0x140B;
constexpr GLenum kQueryResult = 0x8866;
constexpr GLenum kQueryResultAvailable = 0x8867;
// GL_EXT_disjoint_timer_query
constexpr GLenum kTimeElapsed = 0x88BF;
constexpr GLenum kGpuDisjoint = 0x8FBB;

constexpr double kPi = 3.14159265358979323846;

// The constants of SpatialRenderer.kt.
// Largest disparity the maps can store, as a fraction of the eye width, in
// each direction
constexpr float kDisparityRange = 0.1f;
// Search range of the block matching, as a fraction of the disparity width:
// 24 pixels at 480
constexpr float kSearchFraction = 0.05f;
// Weight of a new disparity in the temporal blend (the previous map keeps 0.6)
constexpr float kNewDisparityWeight = 0.4f;
// Disagreement, in disparity pixels, over which the left to right check
// rejects a match
constexpr float kConsistencyTolerance = 1.0f;
// Eye textures larger than this many pixels are scaled down; the synthesis
// upscales them into the output
constexpr double kMaxEyePixels = 1920.0 * 1080.0;
// After the eyes stop changing (paused video), the disparity runs a few more
// times to settle
constexpr int64_t kSettleDelayNs = 100000000LL;
constexpr int32_t kSettleRuns = 4;
// The phones draw at the screen's rate all the time; here the settling runs
// are asked for at most once per frame of a 60 Hz screen
constexpr int64_t kSettlePacingNs = 16000000LL;
// Adaptive quality: step down over this average render time, step up after
// five seconds under the other
constexpr float kSlowMs = 12.0f;
constexpr float kFastMs = 6.0f;
constexpr int32_t kFastSecondsToStepUp = 5;
// After leaving a tier for being slow, the adaptive rule does not step back
// up to it for a minute
constexpr int64_t kStepUpBlockNs = 60000000000LL;
// 360: a view change over these, since the last disparity estimation,
// restarts the temporal blend
constexpr float kMapResetDegrees = 0.5f;
constexpr float kMapResetFovDegrees = 0.5f;
// Without GPU timers, one draw in this many is timed on the CPU around
// glFinish
constexpr int64_t kCpuTimingPeriod = 15;
constexpr int64_t kNanosPerSecond = 1000000000LL;

constexpr int32_t kLow = 0;
constexpr int32_t kMedium = 1;
constexpr int32_t kHigh = 2;
constexpr int32_t kLayoutNone = 4;

// The eye rectangles inside the frame (x, y, width, height), fractions with a
// top left origin, as renderer C reads its frame (the phones' rectangles have
// y up: their TOP_HALF is y 0.5 to 1)
constexpr float kLeftHalf[4] = {0.0f, 0.0f, 0.5f, 1.0f};
constexpr float kRightHalf[4] = {0.5f, 0.0f, 0.5f, 1.0f};
constexpr float kTopHalf[4] = {0.0f, 0.0f, 1.0f, 0.5f};
constexpr float kBottomHalf[4] = {0.0f, 0.5f, 1.0f, 0.5f};
constexpr float kWholeFrame[4] = {0.0f, 0.0f, 1.0f, 1.0f};

// The part of the sphere an equirectangular eye covers, renderer C's uCrop
constexpr float kFullSphere[4] = {0.0f, 0.0f, 1.0f, 1.0f};
constexpr float kHalfSphere[4] = {0.25f, 0.0f, 0.5f, 1.0f};

// SpatialRenderer.kt's eyeRects: the left eye's rectangle, then the right's
void EyeRects(int32_t layout, const float** left, const float** right) {
  switch (layout) {
    case 0:
      *left = kLeftHalf;
      *right = kRightHalf;
      break;
    case 1:
      *left = kTopHalf;
      *right = kBottomHalf;
      break;
    case 2:
      *left = kRightHalf;
      *right = kLeftHalf;
      break;
    case 3:
      *left = kBottomHalf;
      *right = kTopHalf;
      break;
    default:
      *left = kWholeFrame;
      *right = kWholeFrame;
      break;
  }
}

// SpatialRenderer.kt's eyeDisplayAspect: a frame shaped like an ordinary
// picture (about 4:3 to 2:1) holding two eyes stores them squeezed (half side
// by side, half top and bottom), and each eye shows at the frame's shape
float DisplayAspect(int32_t layout, int64_t width, int64_t height) {
  if (width <= 0 || height <= 0) {
    return 16.0f / 9.0f;
  }
  const float frame = static_cast<float>(width) / static_cast<float>(height);
  const bool squeezed = frame >= 1.3f && frame <= 1.95f;
  switch (layout) {
    case 0:
    case 2:
      return squeezed ? frame : frame / 2.0f;
    case 1:
    case 3:
      return squeezed ? frame : frame * 2.0f;
    default:
      return frame;
  }
}

int64_t NowNs() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

int32_t Even(double value) {
  return std::max(2, static_cast<int32_t>(std::floor(value / 2.0)) * 2);
}

int32_t RoundEven(double value) {
  return std::max(2, static_cast<int32_t>(std::lround(value / 2.0)) * 2);
}

int32_t Round(double value) {
  return static_cast<int32_t>(std::lround(value));
}

bool HasExtension(const char* name) {
  const auto extensions =
      reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
  if (extensions == nullptr) {
    return false;
  }
  const auto length = std::strlen(name);
  for (const char* at = std::strstr(extensions, name); at != nullptr;
       at = std::strstr(at + 1, name)) {
    const bool starts = at == extensions || at[-1] == ' ';
    const bool ends = at[length] == '\0' || at[length] == ' ';
    if (starts && ends) {
      return true;
    }
  }
  return false;
}

void ClearErrors() {
  for (int i = 0; i < 32 && glGetError() != GL_NO_ERROR; i++) {
  }
}

const char* QualityName(int32_t quality) {
  return quality == kLow ? "LOW" : (quality == kMedium ? "MEDIUM" : "HIGH");
}

}  // namespace

// Targets and programs

void SpatialRenderer::Target::Bind() const {
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
  glViewport(0, 0, width, height);
}

GLint SpatialRenderer::Program::At(const char* name) {
  auto found = locations.find(name);
  if (found != locations.end()) {
    return found->second;
  }
  const auto location = glGetUniformLocation(id, name);
  locations.emplace(name, location);
  return location;
}

SpatialRenderer::Tier SpatialRenderer::TierOf(int32_t quality) {
  switch (quality) {
    case kLow:
      return Tier{320, 180, 4, false};
    case kHigh:
      return Tier{640, 360, 1, true};
    default:
      return Tier{480, 270, 2, true};
  }
}

bool SpatialRenderer::Prepare(int32_t client_version) {
  if (prepared_) {
    return true;
  }
  if (client_version < 3) {
    error_ = "OpenGL ES " + std::to_string(client_version) +
             ".0 context: the Spatial passes need ES 3.0";
    return false;
  }
  const auto proc = [](const char* name) { return eglGetProcAddress(name); };
  gen_vertex_arrays_ =
      reinterpret_cast<GenVertexArrays>(proc("glGenVertexArrays"));
  bind_vertex_array_ =
      reinterpret_cast<BindVertexArray>(proc("glBindVertexArray"));
  delete_vertex_arrays_ =
      reinterpret_cast<DeleteVertexArrays>(proc("glDeleteVertexArrays"));
  gen_samplers_ = reinterpret_cast<GenSamplers>(proc("glGenSamplers"));
  delete_samplers_ =
      reinterpret_cast<DeleteSamplers>(proc("glDeleteSamplers"));
  bind_sampler_ = reinterpret_cast<BindSampler>(proc("glBindSampler"));
  sampler_parameteri_ =
      reinterpret_cast<SamplerParameteri>(proc("glSamplerParameteri"));
  gen_queries_ = reinterpret_cast<GenQueries>(proc("glGenQueries"));
  delete_queries_ = reinterpret_cast<DeleteQueries>(proc("glDeleteQueries"));
  begin_query_ = reinterpret_cast<BeginQuery>(proc("glBeginQuery"));
  end_query_ = reinterpret_cast<EndQuery>(proc("glEndQuery"));
  get_query_objectuiv_ =
      reinterpret_cast<GetQueryObjectuiv>(proc("glGetQueryObjectuiv"));
  if (gen_vertex_arrays_ == nullptr || bind_vertex_array_ == nullptr ||
      delete_vertex_arrays_ == nullptr || gen_samplers_ == nullptr ||
      delete_samplers_ == nullptr || bind_sampler_ == nullptr ||
      sampler_parameteri_ == nullptr) {
    error_ = "OpenGL ES 3.0 entry points missing";
    return false;
  }
  ClearErrors();
  gen_vertex_arrays_(1, &vertex_array_);
  gen_samplers_(1, &clamp_sampler_);
  sampler_parameteri_(clamp_sampler_, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  sampler_parameteri_(clamp_sampler_, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  sampler_parameteri_(clamp_sampler_, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  sampler_parameteri_(clamp_sampler_, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  map_format_ = PickMapFormat();
  timer_supported_ = HasExtension("GL_EXT_disjoint_timer_query") &&
                     gen_queries_ != nullptr && delete_queries_ != nullptr &&
                     begin_query_ != nullptr && end_query_ != nullptr &&
                     get_query_objectuiv_ != nullptr;
  timer_checked_ = false;
  if (timer_supported_) {
    gen_queries_(static_cast<GLsizei>(queries_.size()), queries_.data());
  }
  ClearErrors();
  prepared_ = true;
  std::cout << "media_kit: SpatialRenderer: "
            << (map_format_ == Format::kRgba16f ? "RGBA16F" : "RGBA8")
            << " maps, "
            << (timer_supported_ ? "GPU timer queries" : "CPU timing")
            << std::endl;
  return true;
}

GLuint SpatialRenderer::Compile(GLenum type,
                                const std::string& source,
                                const char* name) {
  auto shader = glCreateShader(type);
  if (shader == 0) {
    error_ = std::string("cannot create the shader of ") + name;
    return 0;
  }
  const char* text = source.c_str();
  glShaderSource(shader, 1, &text, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (ok != GL_TRUE) {
    char log[2048] = {0};
    glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
    error_ = std::string("shader ") + name + ": " + log;
    std::cout << "media_kit: SpatialRenderer: " << error_ << std::endl;
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

bool SpatialRenderer::Link(Program* program,
                           const std::string& vertex,
                           const std::string& fragment,
                           const char* name) {
  if (program->id != 0) {
    return true;
  }
  const auto vertex_shader = Compile(GL_VERTEX_SHADER, vertex, name);
  if (vertex_shader == 0) {
    return false;
  }
  const auto fragment_shader = Compile(GL_FRAGMENT_SHADER, fragment, name);
  if (fragment_shader == 0) {
    glDeleteShader(vertex_shader);
    return false;
  }
  const auto id = glCreateProgram();
  glAttachShader(id, vertex_shader);
  glAttachShader(id, fragment_shader);
  glLinkProgram(id);
  // The program keeps the compiled stages as long as it needs them
  glDeleteShader(vertex_shader);
  glDeleteShader(fragment_shader);
  GLint ok = GL_FALSE;
  glGetProgramiv(id, GL_LINK_STATUS, &ok);
  if (ok != GL_TRUE) {
    char log[2048] = {0};
    glGetProgramInfoLog(id, sizeof(log) - 1, nullptr, log);
    error_ = std::string("program ") + name + ": " + log;
    std::cout << "media_kit: SpatialRenderer: " << error_ << std::endl;
    glDeleteProgram(id);
    return false;
  }
  program->id = id;
  program->locations.clear();
  return true;
}

bool SpatialRenderer::PreparePrograms() {
  if (!prepared_) {
    return false;
  }
  if (programs_ready_) {
    return true;
  }
  const auto start = NowNs();
  const std::string vertex = spatial_shaders::kVertex;
  const std::string prefix = spatial_shaders::kFragmentPrefix;
  const auto fragment = [&prefix](const char* body) {
    return prefix + body;
  };
  std::string sphere = projection_shaders::kFragmentHeader;
  sphere += "#define PROJECTION_KIND 0\n";
  sphere += projection_shaders::kFragmentCommon;
  sphere += projection_shaders::kFragmentEquirect;
  sphere += spatial_shaders::kEyeSphereMain;
  const bool ready =
      Link(&eye_flat_, vertex,
           prefix + spatial_shaders::kEyeIo + spatial_shaders::kEyeFlat,
           "eye flat") &&
      Link(&eye_sphere_, projection_shaders::kVertexSource, sphere,
           "eye equirectangular") &&
      Link(&copy_, vertex, fragment(spatial_shaders::kCopy), "copy") &&
      Link(&gray_, vertex, fragment(spatial_shaders::kGrayPack), "gray") &&
      Link(&disparity_, vertex, fragment(spatial_shaders::kDisparity),
           "disparity") &&
      Link(&blend_, vertex, fragment(spatial_shaders::kBlend), "blend") &&
      Link(&blur_, vertex, fragment(spatial_shaders::kBlur), "blur") &&
      Link(&synthesis_program_, vertex, fragment(spatial_shaders::kSynthesis),
           "synthesis") &&
      Link(&show_disparity_, vertex,
           fragment(spatial_shaders::kShowDisparity), "show disparity");
  if (!ready) {
    return false;
  }
  programs_ready_ = true;
  std::cout << "media_kit: SpatialRenderer: programs ready in "
            << (NowNs() - start) / 1000000 << " ms" << std::endl;
  return true;
}

SpatialRenderer::Target SpatialRenderer::CreateTarget(int32_t width,
                                                      int32_t height,
                                                      Format format,
                                                      GLint filter) {
  Target target;
  if (width <= 0 || height <= 0) {
    return target;
  }
  ClearErrors();
  glGenTextures(1, &target.texture);
  if (target.texture == 0) {
    return target;
  }
  glBindTexture(GL_TEXTURE_2D, target.texture);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filter);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  if (format == Format::kRgba16f) {
    glTexImage2D(GL_TEXTURE_2D, 0, kRgba16f, width, height, 0, GL_RGBA,
                 kHalfFloat, nullptr);
  } else {
    glTexImage2D(GL_TEXTURE_2D, 0, kRgba8, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, nullptr);
  }
  glBindTexture(GL_TEXTURE_2D, 0);
  if (glGetError() != GL_NO_ERROR) {
    ClearErrors();
    glDeleteTextures(1, &target.texture);
    target.texture = 0;
    return target;
  }
  glGenFramebuffers(1, &target.framebuffer);
  glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         target.texture, 0);
  const auto status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    glDeleteFramebuffers(1, &target.framebuffer);
    glDeleteTextures(1, &target.texture);
    target.framebuffer = 0;
    target.texture = 0;
    return target;
  }
  target.width = width;
  target.height = height;
  return target;
}

void SpatialRenderer::DeleteTarget(Target* target) {
  if (target->framebuffer != 0) {
    glDeleteFramebuffers(1, &target->framebuffer);
  }
  if (target->texture != 0) {
    glDeleteTextures(1, &target->texture);
  }
  *target = Target{};
}

// Half float maps when the driver can render into them, 8 bit maps otherwise
SpatialRenderer::Format SpatialRenderer::PickMapFormat() {
  const bool half_float = HasExtension("GL_EXT_color_buffer_half_float") ||
                          HasExtension("GL_EXT_color_buffer_float");
  if (half_float) {
    auto probe = CreateTarget(4, 4, Format::kRgba16f, GL_NEAREST);
    if (probe.valid()) {
      DeleteTarget(&probe);
      return Format::kRgba16f;
    }
  }
  ClearErrors();
  return Format::kRgba8;
}

void SpatialRenderer::DrawTriangle() {
  bind_vertex_array_(vertex_array_);
  glDrawArrays(GL_TRIANGLES, 0, 3);
}

void SpatialRenderer::BindTexture(int unit, GLuint texture) {
  glActiveTexture(static_cast<GLenum>(GL_TEXTURE0 + unit));
  glBindTexture(GL_TEXTURE_2D, texture);
}

// Binds the output, clears it to black and returns with the viewport on the
// output rectangle
void SpatialRenderer::BeginScreen() {
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, view_width_, view_height_);
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glViewport(out_x_, out_y_, out_width_, out_height_);
}

// Geometry

void SpatialRenderer::OutputSize(const SpatialSetup& setup,
                                 int64_t video_width,
                                 int64_t video_height,
                                 int32_t box_width,
                                 int32_t box_height,
                                 int32_t* width,
                                 int32_t* height) {
  double w = std::max(2, box_width);
  double h = std::max(2, box_height);
  if (setup.projection == 0 && video_width > 0 && video_height > 0) {
    const auto aspect = DisplayAspect(setup.layout, video_width, video_height);
    if (w / h > aspect) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
  }
  // Rounded to the nearest even size (1079.99 lines are 1080), within the box
  *width = std::min(Even(std::max(2, box_width)), RoundEven(w));
  *height = std::min(Even(std::max(2, box_height)), RoundEven(h));
}

float SpatialRenderer::EyeDisplayAspect(const SpatialSetup& setup) const {
  return DisplayAspect(setup.layout, frame_width_, frame_height_);
}

// The output rectangle (the eye's shape letterboxed in the output for a flat
// video, the whole output for a 360 one), and the eye textures to match it.
// True when the eye textures were made again.
bool SpatialRenderer::UpdateGeometry(const SpatialSetup& setup) {
  if (setup.projection == 1) {
    out_x_ = 0;
    out_y_ = 0;
    out_width_ = view_width_;
    out_height_ = view_height_;
  } else {
    const auto aspect = EyeDisplayAspect(setup);
    if (static_cast<float>(view_width_) / view_height_ > aspect) {
      out_height_ = view_height_;
      out_width_ = std::clamp(Round(view_height_ * aspect), 1, view_width_);
    } else {
      out_width_ = view_width_;
      out_height_ = std::clamp(Round(view_width_ / aspect), 1, view_height_);
    }
    out_x_ = (view_width_ - out_width_) / 2;
    out_y_ = (view_height_ - out_height_) / 2;
  }
  const auto scale =
      std::min(1.0, std::sqrt(kMaxEyePixels / (static_cast<double>(out_width_) *
                                               out_height_)));
  const auto eye_width = std::max(1, Round(out_width_ * scale));
  const auto eye_height = std::max(1, Round(out_height_ * scale));
  if (left_eye_.valid() && left_eye_.width == eye_width &&
      left_eye_.height == eye_height) {
    return false;
  }
  if (!left_eye_.valid() && eye_targets_failed_) {
    return false;
  }
  ReleaseEyeTargets();
  auto left = CreateTarget(eye_width, eye_height, Format::kRgba8, GL_LINEAR);
  auto right = CreateTarget(eye_width, eye_height, Format::kRgba8, GL_LINEAR);
  if (!left.valid() || !right.valid()) {
    std::cout << "media_kit: SpatialRenderer: cannot make the " << eye_width
              << " x " << eye_height
              << " eye textures, showing the video directly" << std::endl;
    DeleteTarget(&left);
    DeleteTarget(&right);
    eye_targets_failed_ = true;
    return false;
  }
  left_eye_ = left;
  right_eye_ = right;
  if (static_cast<int64_t>(out_width_) * out_height_ >
      static_cast<int64_t>(eye_width) * eye_height) {
    synthesis_ =
        CreateTarget(eye_width, eye_height, Format::kRgba8, GL_LINEAR);
  }
  eyes_valid_ = false;
  std::cout << "media_kit: SpatialRenderer: eyes " << eye_width << " x "
            << eye_height << " for an output of " << out_width_ << " x "
            << out_height_ << std::endl;
  return true;
}

// Pass 1

// Selects and sets up the program that reads the frame for the projection of
// |setup|; |aspect| is the shape of the target it draws into
void SpatialRenderer::UseEyeProgram(const SpatialSetup& setup,
                                    const Input& input,
                                    float aspect,
                                    Program** used) {
  *used = nullptr;
  if (setup.projection == 1) {
    auto& program = eye_sphere_;
    glUseProgram(program.id);
    BindTexture(0, input.frame_texture);
    // Renderer C's own wrap: the longitude goes on across the seam
    bind_sampler_(0, 0);
    glUniform1i(program.At("uSource"), 0);
    GLfloat columns[9];
    ProjectionRenderer::ViewToSphere(input.view, columns);
    glUniformMatrix3fv(program.At("uViewToSphere"), 1, GL_FALSE, columns);
    const auto fov = std::clamp(input.view.fov, 10.0f, 140.0f) * kPi / 180.0;
    eye_tan_half_ = std::tan(fov / 2.0);
    glUniform2f(program.At("uTanHalfFov"),
                static_cast<GLfloat>(eye_tan_half_ * aspect),
                static_cast<GLfloat>(eye_tan_half_));
    glUniform1f(program.At("uSharp"), input.view.sharp ? 1.0f : 0.0f);
    glUniform4fv(program.At("uCrop"), 1,
                 setup.half_sphere ? kHalfSphere : kFullSphere);
    *used = &program;
    return;
  }
  auto& program = eye_flat_;
  glUseProgram(program.id);
  BindTexture(0, input.frame_texture);
  bind_sampler_(0, clamp_sampler_);
  glUniform1i(program.At("u_video"), 0);
  // The intermediate texture holds the frame with a top left origin, as the
  // rectangles are given: nothing to transform
  static const GLfloat kIdentity[16] = {
      1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f,
      0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f,
  };
  glUniformMatrix4fv(program.At("u_texMatrix"), 1, GL_FALSE, kIdentity);
  *used = &program;
}

// The eye's rectangle; for a flat eye the sides that touch the other eye move
// one texel of the intermediate texture inwards (SpatialRenderer.kt's
// setSeamInset), so that bilinear reads never take the other eye; for an
// equirectangular eye the texels per output pixel of renderer C's filters
void SpatialRenderer::SetEyeRect(Program* program,
                                 const SpatialSetup& setup,
                                 const float rect[4]) {
  if (program == &eye_sphere_) {
    glUniform4fv(program->At("uEye"), 1, rect);
    GLint viewport[4] = {0, 0, 1, 1};
    glGetIntegerv(GL_VIEWPORT, viewport);
    const auto width = std::max(1, viewport[2]);
    const auto height = std::max(1, viewport[3]);
    glUniform2f(program->At("uOutputSize"), static_cast<GLfloat>(width),
                static_cast<GLfloat>(height));
    const auto pixels_per_radian = (height / 2.0) / eye_tan_half_;
    const auto crop = setup.half_sphere ? kHalfSphere[2] : kFullSphere[2];
    const auto texels_per_radian =
        frame_width_ * rect[2] / (2.0 * kPi * std::max(0.01f, crop));
    glUniform1f(program->At("uTexelsPerPixel"),
                static_cast<GLfloat>(texels_per_radian / pixels_per_radian));
    return;
  }
  glUniform4f(program->At("u_rect"), rect[0], rect[1], rect[2], rect[3]);
  const auto texel_x =
      frame_width_ > 0 ? 1.0f / (frame_width_ * rect[2]) : 0.0f;
  const auto texel_y =
      frame_height_ > 0 ? 1.0f / (frame_height_ * rect[3]) : 0.0f;
  glUniform4f(program->At("u_inset"), rect[0] > 0.0f ? texel_x : 0.0f,
              rect[1] > 0.0f ? texel_y : 0.0f,
              rect[0] + rect[2] < 1.0f ? texel_x : 0.0f,
              rect[1] + rect[3] < 1.0f ? texel_y : 0.0f);
}

// Draws the left eye (and the right one too when |stereo|) into the eye
// textures
bool SpatialRenderer::RenderEyes(const SpatialSetup& setup,
                                 const Input& input,
                                 bool stereo) {
  const auto aspect =
      static_cast<float>(left_eye_.width) / std::max(1, left_eye_.height);
  Program* program = nullptr;
  UseEyeProgram(setup, input, aspect, &program);
  if (program == nullptr || program->id == 0) {
    return false;
  }
  const float* left_rect = nullptr;
  const float* right_rect = nullptr;
  EyeRects(setup.layout, &left_rect, &right_rect);
  left_eye_.Bind();
  SetEyeRect(program, setup, left_rect);
  DrawTriangle();
  if (stereo) {
    right_eye_.Bind();
    SetEyeRect(program, setup, right_rect);
    DrawTriangle();
  }
  bind_sampler_(0, 0);
  return true;
}

// Safe fallback: the left eye straight from the frame to the output
void SpatialRenderer::DrawEyeDirect(const SpatialSetup& setup,
                                    const Input& input) {
  BeginScreen();
  const auto aspect =
      static_cast<float>(out_width_) / std::max(1, out_height_);
  Program* program = nullptr;
  UseEyeProgram(setup, input, aspect, &program);
  if (program == nullptr || program->id == 0) {
    return;
  }
  const float* left_rect = nullptr;
  const float* right_rect = nullptr;
  EyeRects(setup.layout, &left_rect, &right_rect);
  SetEyeRect(program, setup, left_rect);
  DrawTriangle();
  bind_sampler_(0, 0);
}

void SpatialRenderer::DrawCopy(const Target& eye) {
  BeginScreen();
  glUseProgram(copy_.id);
  BindTexture(0, eye.texture);
  glUniform1i(copy_.At("u_texture"), 0);
  DrawTriangle();
}

// Passes 2 to 4

int32_t SpatialRenderer::SearchRange() const {
  return std::max(2, Round(disparity_width_ * kSearchFraction));
}

// A disparity in disparity pixels to its encoded offset from 0.5
float SpatialRenderer::EncodeScale() const {
  return 1.0f / (std::max(1, disparity_width_) * 2.0f * kDisparityRange);
}

// The disparity targets for |quality| at the shape of the eyes; false when
// they cannot exist
bool SpatialRenderer::EnsureDisparityTargets(int32_t quality) {
  if (!left_eye_.valid()) {
    return false;
  }
  const auto tier = TierOf(quality);
  // The pixel count of the tier, with the shape of the eye
  const auto aspect =
      static_cast<double>(left_eye_.width) / std::max(1, left_eye_.height);
  const auto height = std::max(
      16, Round(std::sqrt(tier.width * tier.height / aspect)));
  const auto width = std::max(16, Round(height * aspect));
  if (quality == active_quality_ && width == disparity_width_ &&
      height == disparity_height_ && blurred_.valid()) {
    return true;
  }
  ReleaseDisparityTargets();
  gray_left_ = CreateTarget(width, height, Format::kRgba8, GL_NEAREST);
  gray_right_ = CreateTarget(width, height, Format::kRgba8, GL_NEAREST);
  raw_left_ = CreateTarget(width, height, map_format_, GL_NEAREST);
  raw_right_ = CreateTarget(width, height, map_format_, GL_NEAREST);
  maps_[0] = CreateTarget(width, height, map_format_, GL_NEAREST);
  maps_[1] = CreateTarget(width, height, map_format_, GL_NEAREST);
  blur_temp_ = CreateTarget(width, height, map_format_, GL_NEAREST);
  blurred_ = CreateTarget(width, height, map_format_, GL_LINEAR);
  const bool all = gray_left_.valid() && gray_right_.valid() &&
                   raw_left_.valid() && raw_right_.valid() &&
                   maps_[0].valid() && maps_[1].valid() &&
                   blur_temp_.valid() && blurred_.valid();
  if (!all) {
    ReleaseDisparityTargets();
    if (quality != kLow) {
      // The view stays spatial: the next draw tries the lowest tier, and this
      // one is never tried again
      std::cout << "media_kit: SpatialRenderer: cannot make the " << width
                << " x " << height
                << " disparity textures, quality down to LOW" << std::endl;
      BlockStepUp(quality, INT64_MAX);
      quality_ = kLow;
      fast_seconds_ = 0;
      warmup_windows_ = 1;
      return false;
    }
    std::cout << "media_kit: SpatialRenderer: cannot make the " << width
              << " x " << height
              << " disparity textures, showing the left eye" << std::endl;
    disparity_failed_ = true;
    return false;
  }
  active_quality_ = quality;
  disparity_width_ = width;
  disparity_height_ = height;
  current_map_ = 0;
  map_empty_ = true;
  map_reset_ = true;
  // The second that makes the targets and first runs the passes is not
  // representative
  warmup_windows_ = std::max(warmup_windows_, 1);
  std::cout << "media_kit: SpatialRenderer: disparity at " << width << " x "
            << height << ", quality " << QualityName(quality) << ", "
            << (map_format_ == Format::kRgba16f ? "RGBA16F" : "RGBA8")
            << " maps" << std::endl;
  return true;
}

// 360 only: whether the eyes show another view than the one the current map
// was computed for. The maps live in the view's space, so blending the old one
// in would trail the depth edges behind the picture while the view turns or
// zooms. Changes under a threshold keep the temporal blend.
bool SpatialRenderer::ViewChangedSinceMap(const SpatialSetup& setup) const {
  if (setup.projection != 1 || !has_map_view_) {
    return false;
  }
  auto yaw_change = std::fmod(std::abs(last_yaw_ - map_yaw_), 360.0f);
  if (yaw_change > 180.0f) {
    yaw_change = 360.0f - yaw_change;
  }
  return yaw_change > kMapResetDegrees ||
         std::abs(last_pitch_ - map_pitch_) > kMapResetDegrees ||
         std::abs(last_fov_ - map_fov_) > kMapResetFovDegrees;
}

// |fresh_view| drops the temporal history: the new map gets the full weight
void SpatialRenderer::ComputeDisparity(const Tier& tier, bool fresh_view) {
  auto& previous = maps_[current_map_];
  auto& next = maps_[1 - current_map_];
  const auto encode = EncodeScale();

  // Pass 2: packed grey of both eyes
  glUseProgram(gray_.id);
  glUniform1i(gray_.At("u_eye"), 0);
  glUniform2f(gray_.At("u_texel"), 1.0f / disparity_width_,
              1.0f / disparity_height_);
  gray_left_.Bind();
  BindTexture(0, left_eye_.texture);
  DrawTriangle();
  gray_right_.Bind();
  BindTexture(0, right_eye_.texture);
  DrawTriangle();

  // Pass 3: block matching from the left eye, and from the right eye for the
  // consistency check
  glUseProgram(disparity_.id);
  glUniform1i(disparity_.At("u_reference"), 0);
  glUniform1i(disparity_.At("u_other"), 1);
  glUniform1i(disparity_.At("u_searchRange"), SearchRange());
  glUniform1f(disparity_.At("u_encode"), encode);
  raw_left_.Bind();
  glUniform1i(disparity_.At("u_direction"), 1);
  BindTexture(0, gray_left_.texture);
  BindTexture(1, gray_right_.texture);
  DrawTriangle();
  if (tier.consistency_check) {
    raw_right_.Bind();
    glUniform1i(disparity_.At("u_direction"), -1);
    BindTexture(0, gray_right_.texture);
    BindTexture(1, gray_left_.texture);
    DrawTriangle();
  }

  // Consistency check and temporal blend into the other map of the pair
  if (map_reset_) {
    previous.Bind();
    glClearColor(0.5f, 0.0f, 0.5f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  glUseProgram(blend_.id);
  glUniform1i(blend_.At("u_rawLeft"), 0);
  glUniform1i(blend_.At("u_rawRight"), 1);
  glUniform1i(blend_.At("u_previous"), 2);
  glUniform1i(blend_.At("u_check"), tier.consistency_check ? 1 : 0);
  glUniform1f(blend_.At("u_newWeight"),
              map_reset_ || fresh_view ? 1.0f : kNewDisparityWeight);
  glUniform1f(blend_.At("u_encode"), encode);
  glUniform1f(blend_.At("u_tolerance"), kConsistencyTolerance);
  next.Bind();
  BindTexture(0, raw_left_.texture);
  BindTexture(1, raw_right_.texture);
  BindTexture(2, previous.texture);
  DrawTriangle();
  current_map_ = 1 - current_map_;

  // Pass 4: separable blur, horizontal then vertical
  glUseProgram(blur_.id);
  glUniform1i(blur_.At("u_map"), 0);
  blur_temp_.Bind();
  glUniform2i(blur_.At("u_direction"), 1, 0);
  BindTexture(0, next.texture);
  DrawTriangle();
  blurred_.Bind();
  glUniform2i(blur_.At("u_direction"), 0, 1);
  BindTexture(0, blur_temp_.texture);
  DrawTriangle();

  // Leave the units clean for the next passes
  BindTexture(2, 0);
  BindTexture(1, 0);
  map_reset_ = false;
  map_empty_ = false;
  has_map_view_ = true;
  map_yaw_ = last_yaw_;
  map_pitch_ = last_pitch_;
  map_fov_ = last_fov_;
  disparity_runs_in_window_++;
  counters_.disparity_runs++;
}

// Pass 5

void SpatialRenderer::DrawSynthesis(const Tier& tier, float viewpoint) {
  const bool scaled = synthesis_.valid();
  if (scaled) {
    synthesis_.Bind();
  } else {
    BeginScreen();
  }
  auto& program = synthesis_program_;
  glUseProgram(program.id);
  glUniform1i(program.At("u_left"), 0);
  glUniform1i(program.At("u_right"), 1);
  glUniform1i(program.At("u_map"), 2);
  glUniform1f(program.At("u_viewpoint"), std::clamp(viewpoint, 0.0f, 1.0f));
  glUniform1f(program.At("u_decode"), 2.0f * kDisparityRange);
  glUniform1f(program.At("u_threshold"), 1.0f / disparity_width_);
  glUniform1f(program.At("u_searchStep"), 2.0f / disparity_width_);
  glUniform1i(program.At("u_hasRightMap"), tier.consistency_check ? 1 : 0);
  BindTexture(0, left_eye_.texture);
  BindTexture(1, right_eye_.texture);
  BindTexture(2, blurred_.texture);
  DrawTriangle();
  BindTexture(2, 0);
  BindTexture(1, 0);
  if (scaled) {
    DrawCopy(synthesis_);
  }
}

void SpatialRenderer::DrawDisparity() {
  BeginScreen();
  glUseProgram(show_disparity_.id);
  glUniform1i(show_disparity_.At("u_map"), 0);
  glUniform1f(show_disparity_.At("u_gain"),
              0.5f / (std::max(1, SearchRange()) * EncodeScale()));
  BindTexture(0, blurred_.texture);
  DrawTriangle();
}

// The draw

bool SpatialRenderer::Draw(const SpatialSetup& setup, const Input& input) {
  if (!prepared_ || !programs_ready_ || input.frame_texture == 0 ||
      input.frame_width < 1 || input.frame_height < 1) {
    return false;
  }
  const auto now = input.now_ns;
  view_width_ = std::max(1, input.width);
  view_height_ = std::max(1, input.height);
  frame_width_ = input.frame_width;
  frame_height_ = input.frame_height;
  // The tier Dart asked for, again whenever it asks
  if (setup.quality != requested_quality_ || setup.adaptive != adaptive_) {
    requested_quality_ = setup.quality;
    adaptive_ = setup.adaptive;
    quality_ = std::clamp(setup.quality, kLow, kHigh);
    fast_seconds_ = 0;
    warmup_windows_ = std::max(warmup_windows_, 1);
  }
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_CULL_FACE);
  glDisable(GL_DITHER);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

  // A settling run asked for that this draw cannot make (no eyes, no maps)
  // is not asked for again, so that the timer never loops
  const bool settle_was_due = SettleDue(now);
  const auto settle_runs_before = settle_runs_;
  const auto eye_change_before = last_eye_change_ns_;

  frame_count_++;
  frames_in_window_++;
  counters_.draws++;
  const bool cpu_timing =
      !timer_supported_ && frame_count_ % kCpuTimingPeriod == 0;
  if (cpu_timing) {
    glFinish();
    cpu_timing_start_ns_ = NowNs();
  }
  BeginGpuTimer();

  const auto layout = setup.layout;
  const auto projection = setup.projection;
  const int half_sphere = setup.half_sphere ? 1 : 0;
  const auto fov = std::clamp(input.view.fov, 10.0f, 140.0f);
  const bool eyes_recreated = UpdateGeometry(setup);
  if (!left_eye_.valid() || !right_eye_.valid()) {
    DrawEyeDirect(setup, input);
  } else {
    // Pass 1: the eyes change only with a new frame, a new layout or
    // coverage, or a new view of a 360 video
    const bool source_changed = layout != last_layout_ ||
                                projection != last_projection_ ||
                                half_sphere != last_half_sphere_;
    const bool view_moved =
        projection == 1 &&
        (!has_last_view_ || input.view.yaw != last_yaw_ ||
         input.view.pitch != last_pitch_ || fov != last_fov_ ||
         input.view.sharp != last_sharp_);
    const bool eyes_changed = input.new_frame || source_changed ||
                              view_moved || eyes_recreated || !eyes_valid_;
    const bool stereo =
        layout != kLayoutNone && programs_ready_ && !disparity_failed_;
    stereo_ = stereo;
    bool eyes_ok = true;
    if (eyes_changed) {
      if (!RenderEyes(setup, input, stereo)) {
        DrawEyeDirect(setup, input);
        eyes_ok = false;
      } else {
        eyes_valid_ = true;
        last_layout_ = layout;
        last_projection_ = projection;
        last_half_sphere_ = half_sphere;
        last_yaw_ = input.view.yaw;
        last_pitch_ = input.view.pitch;
        last_fov_ = fov;
        last_sharp_ = input.view.sharp;
        has_last_view_ = true;
      }
    }
    if (eyes_ok) {
      if (source_changed || eyes_recreated) {
        map_reset_ = true;
      }
      // A video that is not stereoscopic gives a flat result: the eye as it is
      if (!stereo || !EnsureDisparityTargets(quality_)) {
        DrawCopy(left_eye_);
      } else {
        spatial_frames_in_window_++;
        // Passes 2 to 4, every few changed frames, then a few more times once
        // the eyes stop changing
        if (eyes_changed) {
          changes_since_disparity_++;
          last_eye_change_ns_ = now;
          settle_runs_ = 0;
        }
        const auto tier = TierOf(quality_);
        const bool settle = now - last_eye_change_ns_ > kSettleDelayNs &&
                            settle_runs_ < kSettleRuns;
        if (map_reset_ || map_empty_ ||
            changes_since_disparity_ >= tier.interval || settle) {
          if (settle) {
            settle_runs_++;
            counters_.settle_runs++;
          }
          ComputeDisparity(tier, ViewChangedSinceMap(setup));
          changes_since_disparity_ = 0;
        }
        // Pass 5
        if (!blurred_.valid() || map_empty_) {
          DrawCopy(left_eye_);
        } else if (input.show_disparity) {
          DrawDisparity();
        } else {
          DrawSynthesis(tier, input.viewpoint);
        }
      }
    }
  }

  if (settle_was_due && settle_runs_ == settle_runs_before &&
      last_eye_change_ns_ == eye_change_before) {
    settle_runs_ = kSettleRuns;
  }
  EndGpuTimer();
  if (cpu_timing) {
    glFinish();
    AddTimingSample(static_cast<float>(NowNs() - cpu_timing_start_ns_) / 1e6f);
  }
  UpdateStatistics(now);
  last_draw_ns_ = now;
  counters_.viewpoint = input.viewpoint;

  // The defaults mpv expects at its next render (render_gl.h, "OpenGL state")
  for (int unit = 2; unit >= 0; unit--) {
    BindTexture(unit, 0);
    bind_sampler_(static_cast<GLuint>(unit), 0);
  }
  glUseProgram(0);
  bind_vertex_array_(0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
  glViewport(0, 0, view_width_, view_height_);
  return true;
}

int64_t SpatialRenderer::NextSettleNs() const {
  if (!stereo_ || map_empty_ || settle_runs_ >= kSettleRuns ||
      last_eye_change_ns_ == 0) {
    return 0;
  }
  return std::max(last_eye_change_ns_ + kSettleDelayNs + 1,
                  last_draw_ns_ + kSettlePacingNs);
}

void SpatialRenderer::ReadRow(int32_t width,
                              int32_t height,
                              std::vector<uint32_t>* row) {
  row->assign(std::max(1, width), 0u);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glReadPixels(0, height / 2, std::max(1, width), 1, GL_RGBA,
               GL_UNSIGNED_BYTE, row->data());
}

// Timing and adaptive quality

void SpatialRenderer::BeginGpuTimer() {
  active_query_ = -1;
  if (!timer_supported_) {
    return;
  }
  CollectGpuTimers();
  const auto slot = next_query_;
  if (query_pending_[slot]) {
    return;
  }
  if (!timer_checked_) {
    ClearErrors();
  }
  begin_query_(kTimeElapsed, queries_[slot]);
  if (!timer_checked_) {
    timer_checked_ = true;
    if (glGetError() != GL_NO_ERROR) {
      std::cout << "media_kit: SpatialRenderer: GPU timer queries refused, "
                   "timing on the CPU"
                << std::endl;
      timer_supported_ = false;
      return;
    }
  }
  active_query_ = slot;
}

void SpatialRenderer::EndGpuTimer() {
  const auto slot = active_query_;
  if (slot < 0) {
    return;
  }
  end_query_(kTimeElapsed);
  query_pending_[slot] = true;
  next_query_ = (slot + 1) % static_cast<int>(queries_.size());
  active_query_ = -1;
}

// Reads the finished timer queries; a disjoint event (a frequency change, a
// context switch) voids them
void SpatialRenderer::CollectGpuTimers() {
  GLint disjoint = 0;
  glGetIntegerv(kGpuDisjoint, &disjoint);
  for (size_t slot = 0; slot < queries_.size(); slot++) {
    if (!query_pending_[slot]) {
      continue;
    }
    GLuint available = 0;
    get_query_objectuiv_(queries_[slot], kQueryResultAvailable, &available);
    if (available == 0) {
      continue;
    }
    GLuint elapsed = 0;
    get_query_objectuiv_(queries_[slot], kQueryResult, &elapsed);
    query_pending_[slot] = false;
    if (disjoint == 0) {
      AddTimingSample(static_cast<float>(elapsed) / 1e6f);
    }
  }
}

void SpatialRenderer::AddTimingSample(float milliseconds) {
  timing_sum_ += milliseconds;
  timing_count_++;
}

// Once per second: the statistics, and the adaptive quality rule
void SpatialRenderer::UpdateStatistics(int64_t now_ns) {
  if (window_start_ns_ == 0) {
    window_start_ns_ = now_ns;
    return;
  }
  const auto elapsed = now_ns - window_start_ns_;
  if (elapsed < kNanosPerSecond) {
    return;
  }
  const auto seconds =
      static_cast<float>(elapsed) / static_cast<float>(kNanosPerSecond);
  counters_.render_fps = static_cast<float>(frames_in_window_) / seconds;
  counters_.disparity_fps =
      static_cast<float>(disparity_runs_in_window_) / seconds;
  const bool measured = timing_count_ > 0;
  const auto average_ms =
      measured ? timing_sum_ / static_cast<float>(timing_count_)
               : counters_.render_ms;
  counters_.render_ms = average_ms;
  // Only the seconds that ran the spatial passes are judged, and only those
  // that estimated disparity step up
  if (adaptive_ && measured && spatial_frames_in_window_ > 0) {
    Adapt(average_ms, disparity_runs_in_window_ > 0, now_ns);
  }
  window_start_ns_ = now_ns;
  frames_in_window_ = 0;
  disparity_runs_in_window_ = 0;
  spatial_frames_in_window_ = 0;
  timing_sum_ = 0.0f;
  timing_count_ = 0;
}

// Steps down after a slow second, and up after kFastSecondsToStepUp fast ones.
// A tier left for being slow stays out of reach for kStepUpBlockNs, so that a
// GPU fast at one tier but slow at the next does not switch back and forth
// (each switch restarts the disparity maps).
void SpatialRenderer::Adapt(float average_ms, bool estimated, int64_t now_ns) {
  if (warmup_windows_ > 0) {
    // The first second after a change mixes both tiers
    warmup_windows_--;
    return;
  }
  const auto current = quality_;
  if (average_ms > kSlowMs) {
    fast_seconds_ = 0;
    if (current != kLow) {
      BlockStepUp(current, now_ns + kStepUpBlockNs);
      quality_ = current - 1;
      warmup_windows_ = 1;
      counters_.quality_changes++;
      std::cout << "media_kit: SpatialRenderer: render at " << average_ms
                << " ms, quality down to " << QualityName(quality_)
                << std::endl;
    }
  } else if (average_ms < kFastMs && estimated) {
    fast_seconds_++;
    if (fast_seconds_ >= kFastSecondsToStepUp && current != kHigh &&
        now_ns >= step_up_blocked_until_[current + 1]) {
      quality_ = current + 1;
      fast_seconds_ = 0;
      warmup_windows_ = 1;
      counters_.quality_changes++;
      std::cout << "media_kit: SpatialRenderer: render at " << average_ms
                << " ms, quality up to " << QualityName(quality_) << std::endl;
    }
  } else {
    fast_seconds_ = 0;
  }
}

// Keeps the adaptive rule from stepping up to |quality| before |until_ns|,
// without shortening an earlier block
void SpatialRenderer::BlockStepUp(int32_t quality, int64_t until_ns) {
  if (quality < kLow || quality > kHigh) {
    return;
  }
  step_up_blocked_until_[quality] =
      std::max(step_up_blocked_until_[quality], until_ns);
}

SpatialCounters SpatialRenderer::TakeCounters() {
  auto counters = counters_;
  counters.disparity_width = disparity_width_;
  counters.disparity_height = disparity_height_;
  counters.eye_width = left_eye_.width;
  counters.eye_height = left_eye_.height;
  counters.quality = active_quality_ >= 0 ? active_quality_ : quality_;
  counters.stereo = stereo_;
  counters.gpu_timer = timer_supported_;
  counters.half_float_maps = map_format_ == Format::kRgba16f;
  counters_.draws = 0;
  counters_.disparity_runs = 0;
  counters_.settle_runs = 0;
  counters_.quality_changes = 0;
  return counters;
}

// Cleanup

void SpatialRenderer::ReleaseEyeTargets() {
  DeleteTarget(&left_eye_);
  DeleteTarget(&right_eye_);
  DeleteTarget(&synthesis_);
  eyes_valid_ = false;
}

void SpatialRenderer::ReleaseDisparityTargets() {
  DeleteTarget(&gray_left_);
  DeleteTarget(&gray_right_);
  DeleteTarget(&raw_left_);
  DeleteTarget(&raw_right_);
  DeleteTarget(&maps_[0]);
  DeleteTarget(&maps_[1]);
  DeleteTarget(&blur_temp_);
  DeleteTarget(&blurred_);
  active_quality_ = -1;
  map_empty_ = true;
  map_reset_ = true;
}

void SpatialRenderer::Release() {
  ReleaseEyeTargets();
  ReleaseDisparityTargets();
  for (auto* program : {&eye_flat_, &eye_sphere_, &copy_, &gray_, &disparity_,
                        &blend_, &blur_, &synthesis_program_,
                        &show_disparity_}) {
    if (program->id != 0) {
      glDeleteProgram(program->id);
    }
    *program = Program{};
  }
  if (vertex_array_ != 0 && delete_vertex_arrays_ != nullptr) {
    delete_vertex_arrays_(1, &vertex_array_);
  }
  vertex_array_ = 0;
  if (clamp_sampler_ != 0 && delete_samplers_ != nullptr) {
    delete_samplers_(1, &clamp_sampler_);
  }
  clamp_sampler_ = 0;
  if (timer_supported_ && delete_queries_ != nullptr) {
    delete_queries_(static_cast<GLsizei>(queries_.size()), queries_.data());
  }
  ResetState();
}

void SpatialRenderer::ResetState() {
  prepared_ = false;
  programs_ready_ = false;
  eye_targets_failed_ = false;
  eyes_valid_ = false;
  last_layout_ = -1;
  last_projection_ = -1;
  last_half_sphere_ = -1;
  has_last_view_ = false;
  active_quality_ = -1;
  disparity_width_ = 0;
  disparity_height_ = 0;
  disparity_failed_ = false;
  map_empty_ = true;
  map_reset_ = true;
  has_map_view_ = false;
  changes_since_disparity_ = 0;
  last_eye_change_ns_ = 0;
  last_draw_ns_ = 0;
  settle_runs_ = 0;
  stereo_ = false;
  requested_quality_ = -1;
  timer_supported_ = false;
  timer_checked_ = false;
  queries_.fill(0);
  query_pending_.fill(false);
  next_query_ = 0;
  active_query_ = -1;
  frame_count_ = 0;
  window_start_ns_ = 0;
  frames_in_window_ = 0;
  disparity_runs_in_window_ = 0;
  spatial_frames_in_window_ = 0;
  timing_sum_ = 0.0f;
  timing_count_ = 0;
  fast_seconds_ = 0;
  warmup_windows_ = 1;
  step_up_blocked_until_.fill(INT64_MIN);
  counters_ = SpatialCounters{};
}
