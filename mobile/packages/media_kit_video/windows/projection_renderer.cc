// Immuch360: renderer C (IMMUCH360-NOTE.md, patch 6); see the header.

// Windows.h, which the EGL headers include, would otherwise define min and max
// as macros over std::min and std::max
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "projection_renderer.h"

#include <algorithm>
#include <cmath>
#include <iostream>

#include "projection_shaders.h"

namespace {

// GL_RGBA8 of OpenGL ES 3.0 (GL_RGBA8_OES of the ES 2.0 headers the libs
// package ships)
constexpr GLenum kRgba8 = 0x8058;

constexpr double kPi = 3.14159265358979323846;

// The uniforms of the stitches that Dart may set by name, with their sizes:
// what RawStitchShaders.kt lists, the half texels left out (computed in the
// pass)
bool IsStitchUniform(const std::string& name) {
  static const char* kNames[] = {
      "uViewToLens0", "uViewToLens1", "uIntr0",       "uIntr1",
      "uK0",          "uK1",          "uX0",          "uX1",
      "uRegion0",     "uRegion1",     "uTexOf0",      "uTexOf1",
      "uEquidistantFocal0", "uEquidistantFocal1", "uModel", "uSquare",
      "uTheta",       "uViewToCamera", "uFace0",      "uFace1",
      "uFace2",       "uFace3",       "uFace4",       "uFace5",
      "uFaceSlot0",   "uFaceSlot1",   "uFaceSlot2",   "uFaceSlot3",
      "uFaceSlot4",   "uFaceSlot5",   "uEac",         "uEacRight",
      "uTrackSize",
  };
  for (const auto* known : kNames) {
    if (name == known) {
      return true;
    }
  }
  return false;
}

int32_t Even(double value) {
  return std::max(2, static_cast<int32_t>(std::floor(value / 2.0)) * 2);
}

}  // namespace

void ProjectionSetup::OutputSize(int32_t* width, int32_t* height) const {
  double w = std::max(1, output_width);
  double h = std::max(1, output_height);
  if (max_output_height > 0 && h > max_output_height) {
    w = w * max_output_height / h;
    h = max_output_height;
  }
  *width = Even(w);
  *height = Even(h);
}

bool ProjectionRenderer::Prepare(int32_t client_version) {
  if (prepared_) {
    return true;
  }
  if (client_version < 3) {
    error_ = "OpenGL ES " + std::to_string(client_version) +
             ".0 context: renderer C needs ES 3.0";
    return false;
  }
  tex_storage_2d_ =
      reinterpret_cast<TexStorage2D>(eglGetProcAddress("glTexStorage2D"));
  gen_vertex_arrays_ =
      reinterpret_cast<GenVertexArrays>(eglGetProcAddress("glGenVertexArrays"));
  bind_vertex_array_ =
      reinterpret_cast<BindVertexArray>(eglGetProcAddress("glBindVertexArray"));
  delete_vertex_arrays_ = reinterpret_cast<DeleteVertexArrays>(
      eglGetProcAddress("glDeleteVertexArrays"));
  bind_sampler_ =
      reinterpret_cast<BindSampler>(eglGetProcAddress("glBindSampler"));
  if (tex_storage_2d_ == nullptr || gen_vertex_arrays_ == nullptr ||
      bind_vertex_array_ == nullptr || delete_vertex_arrays_ == nullptr ||
      bind_sampler_ == nullptr) {
    error_ = "OpenGL ES 3.0 entry points missing";
    return false;
  }
  const auto renderer =
      reinterpret_cast<const char*>(glGetString(GL_RENDERER));
  gl_renderer_ = renderer != nullptr ? renderer : "";
  // No attribute is read (the vertex shader makes its triangle from
  // gl_VertexID), but a vertex array of its own keeps the draw away from
  // whatever mpv left bound in the default one.
  gen_vertex_arrays_(1, &vertex_array_);
  prepared_ = true;
  return true;
}

bool ProjectionRenderer::EnsureFrame(int64_t video_width,
                                     int64_t video_height,
                                     const ProjectionSetup& setup) {
  if (video_width < 1 || video_height < 1) {
    return false;
  }
  GLint max_texture = 0;
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_texture);
  double scale = 1.0;
  if (setup.max_frame_width > 0 && video_width > setup.max_frame_width) {
    scale = std::min(scale, static_cast<double>(setup.max_frame_width) /
                                static_cast<double>(video_width));
  }
  const auto pixels = static_cast<double>(video_width) * video_height;
  if (setup.max_frame_pixels > 0 && pixels > setup.max_frame_pixels) {
    scale = std::min(
        scale, std::sqrt(static_cast<double>(setup.max_frame_pixels) / pixels));
  }
  if (max_texture > 0) {
    scale = std::min(scale, static_cast<double>(max_texture) /
                                std::max(video_width, video_height));
  }
  const auto width = Even(video_width * scale);
  const auto height = Even(video_height * scale);
  if (frame_fbo_ != 0 && width == frame_width_ && height == frame_height_) {
    return true;
  }
  if (frame_fbo_ != 0) {
    glDeleteFramebuffers(1, &frame_fbo_);
    frame_fbo_ = 0;
  }
  if (frame_texture_ != 0) {
    glDeleteTextures(1, &frame_texture_);
    frame_texture_ = 0;
  }
  has_frame_ = false;
  frame_width_ = 0;
  frame_height_ = 0;
  glGenTextures(1, &frame_texture_);
  glBindTexture(GL_TEXTURE_2D, frame_texture_);
  // 8 bits a channel: Flutter's texture is BGRA 8 anyway and mpv tone maps
  // HDR before it draws, so a 16 bit frame would double the memory (133 MB
  // for a 5.7K video) for nothing that shows
  tex_storage_2d_(GL_TEXTURE_2D, 1, kRgba8, width, height);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  // Across the seam of an equirectangular frame the longitude goes on: a
  // bilinear read at its last column takes the first one
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glBindTexture(GL_TEXTURE_2D, 0);
  glGenFramebuffers(1, &frame_fbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, frame_fbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         frame_texture_, 0);
  const auto status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    error_ = "intermediate FBO incomplete (" + std::to_string(status) + ")";
    glDeleteFramebuffers(1, &frame_fbo_);
    glDeleteTextures(1, &frame_texture_);
    frame_fbo_ = 0;
    frame_texture_ = 0;
    return false;
  }
  frame_width_ = width;
  frame_height_ = height;
  std::cout << "media_kit: ProjectionRenderer: frame " << width << " x "
            << height << " for a video of " << video_width << " x "
            << video_height << std::endl;
  return true;
}

GLuint ProjectionRenderer::Compile(GLenum type, const std::string& source) {
  auto shader = glCreateShader(type);
  const char* text = source.c_str();
  glShaderSource(shader, 1, &text, nullptr);
  glCompileShader(shader);
  GLint ok = GL_FALSE;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (ok != GL_TRUE) {
    char log[1024] = {0};
    glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
    error_ = std::string("shader: ") + log;
    std::cout << "media_kit: ProjectionRenderer: " << error_ << std::endl;
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

GLuint ProjectionRenderer::Program(int32_t kind) {
  if (kind < 0 || kind > 2) {
    error_ = "unknown projection " + std::to_string(kind);
    return 0;
  }
  if (programs_[kind] != 0 || program_failed_[kind]) {
    return programs_[kind];
  }
  if (vertex_shader_ == 0) {
    vertex_shader_ =
        Compile(GL_VERTEX_SHADER, projection_shaders::kVertexSource);
    if (vertex_shader_ == 0) {
      program_failed_[kind] = true;
      return 0;
    }
  }
  std::string source = projection_shaders::kFragmentHeader;
  source += "#define PROJECTION_KIND " + std::to_string(kind) + "\n";
  source += projection_shaders::kFragmentCommon;
  if (kind == 0) {
    source += projection_shaders::kFragmentEquirect;
  } else {
    source += projection_shaders::kFragmentStreams;
    source += kind == 1 ? projection_shaders::kFragmentFisheye
                        : projection_shaders::kFragmentEac;
  }
  source += projection_shaders::kFragmentMain;
  auto fragment = Compile(GL_FRAGMENT_SHADER, source);
  if (fragment == 0) {
    program_failed_[kind] = true;
    return 0;
  }
  auto program = glCreateProgram();
  glAttachShader(program, vertex_shader_);
  glAttachShader(program, fragment);
  glLinkProgram(program);
  glDeleteShader(fragment);
  GLint ok = GL_FALSE;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (ok != GL_TRUE) {
    char log[1024] = {0};
    glGetProgramInfoLog(program, sizeof(log) - 1, nullptr, log);
    error_ = std::string("program: ") + log;
    std::cout << "media_kit: ProjectionRenderer: " << error_ << std::endl;
    glDeleteProgram(program);
    program_failed_[kind] = true;
    return 0;
  }
  programs_[kind] = program;
  return program;
}

void ProjectionRenderer::SetUniforms(GLuint program,
                                     const ProjectionSetup& setup,
                                     const ProjectionView& view,
                                     int32_t width,
                                     int32_t height) {
  const auto location = [program](const char* name) {
    return glGetUniformLocation(program, name);
  };
  glUniform1i(location("uSource"), 0);
  // A ray of the view to the sphere: pitched up about x, then turned about
  // y (the yaw to the right), so that the centre of the view looks at
  // longitude |yaw| and latitude |pitch|, as the photo sphere does
  const auto yaw = view.yaw * kPi / 180.0;
  const auto pitch = std::clamp(view.pitch, -90.0f, 90.0f) * kPi / 180.0;
  const auto cy = std::cos(yaw), sy = std::sin(yaw);
  const auto cp = std::cos(pitch), sp = std::sin(pitch);
  // Rows of Ry(yaw) * Rx(pitch)
  const double rows[9] = {
      cy, -sy * sp, sy * cp,  //
      0,  cp,       sp,       //
      -sy, -cy * sp, cy * cp,
  };
  GLfloat columns[9];
  for (int i = 0; i < 9; i++) {
    columns[i] = static_cast<GLfloat>(rows[(i % 3) * 3 + i / 3]);
  }
  glUniformMatrix3fv(location("uViewToSphere"), 1, GL_FALSE, columns);
  const auto fov = std::clamp(view.fov, 1.0f, 170.0f) * kPi / 180.0;
  const auto tan_half = std::tan(fov / 2.0);
  const auto aspect = static_cast<double>(width) / std::max(1, height);
  glUniform2f(location("uTanHalfFov"), static_cast<GLfloat>(tan_half * aspect),
              static_cast<GLfloat>(tan_half));
  glUniform1f(location("uSharp"), view.sharp ? 1.0f : 0.0f);
  glUniform2f(location("uOutputSize"), static_cast<GLfloat>(width),
              static_cast<GLfloat>(height));
  const auto pixels_per_radian = (height / 2.0) / tan_half;
  auto texels_per_radian = frame_width_ / (2.0 * kPi);
  if (setup.kind == 0) {
    texels_per_radian =
        frame_width_ * setup.eye[2] / (2.0 * kPi * std::max(0.01f, setup.crop[2]));
  }
  glUniform1f(location("uTexelsPerPixel"),
              static_cast<GLfloat>(texels_per_radian / pixels_per_radian));
  if (setup.kind == 0) {
    glUniform4fv(location("uEye"), 1, setup.eye);
    glUniform4fv(location("uCrop"), 1, setup.crop);
    return;
  }
  glUniform1f(location("uTracks"),
              static_cast<GLfloat>(std::max(1, setup.tracks)));
  glUniform2fv(location("uEnabled"), 1, setup.enabled);
  for (const auto& [name, values] : setup.uniforms) {
    if (!IsStitchUniform(name)) {
      continue;
    }
    const auto at = location(name.c_str());
    if (at < 0) {
      continue;
    }
    switch (values.size()) {
      case 1:
        glUniform1fv(at, 1, values.data());
        break;
      case 2:
        glUniform2fv(at, 1, values.data());
        break;
      case 3:
        glUniform3fv(at, 1, values.data());
        break;
      case 4:
        glUniform4fv(at, 1, values.data());
        break;
      case 9:
        // Column major already, as RawStitchUniforms.columnMajor writes it
        glUniformMatrix3fv(at, 1, GL_FALSE, values.data());
        break;
      default:
        break;
    }
  }
}

bool ProjectionRenderer::DrawView(const ProjectionSetup& setup,
                                  const ProjectionView& view,
                                  int32_t width,
                                  int32_t height) {
  if (!prepared_ || frame_texture_ == 0 || !has_frame_) {
    return false;
  }
  const auto program = Program(setup.kind);
  if (program == 0) {
    return false;
  }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, width, height);
  glDisable(GL_BLEND);
  glDisable(GL_SCISSOR_TEST);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_CULL_FACE);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glUseProgram(program);
  bind_vertex_array_(vertex_array_);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, frame_texture_);
  bind_sampler_(0, 0);
  SetUniforms(program, setup, view, width, height);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  // The defaults mpv expects at its next render (render_gl.h, "OpenGL state")
  glBindTexture(GL_TEXTURE_2D, 0);
  bind_vertex_array_(0);
  glUseProgram(0);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  return true;
}

void ProjectionRenderer::ReadProbe(int32_t width,
                                   int32_t height,
                                   uint32_t out[5]) {
  const int32_t points[5][2] = {
      {width / 2, height / 2},
      {width / 2, height / 8},
      {width / 2, height - height / 8 - 1},
      {width / 8, height / 2},
      {width - width / 8 - 1, height / 2},
  };
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  for (int i = 0; i < 5; i++) {
    uint32_t pixel = 0;
    glReadPixels(points[i][0], points[i][1], 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                 &pixel);
    out[i] = pixel;
  }
}

void ProjectionRenderer::Release() {
  if (frame_fbo_ != 0) {
    glDeleteFramebuffers(1, &frame_fbo_);
    frame_fbo_ = 0;
  }
  if (frame_texture_ != 0) {
    glDeleteTextures(1, &frame_texture_);
    frame_texture_ = 0;
  }
  for (auto& program : programs_) {
    if (program != 0) {
      glDeleteProgram(program);
      program = 0;
    }
  }
  for (auto& failed : program_failed_) {
    failed = false;
  }
  if (vertex_shader_ != 0) {
    glDeleteShader(vertex_shader_);
    vertex_shader_ = 0;
  }
  if (vertex_array_ != 0 && delete_vertex_arrays_ != nullptr) {
    delete_vertex_arrays_(1, &vertex_array_);
    vertex_array_ = 0;
  }
  frame_width_ = 0;
  frame_height_ = 0;
  has_frame_ = false;
  prepared_ = false;
}
