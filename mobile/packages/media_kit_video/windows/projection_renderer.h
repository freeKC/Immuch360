// Immuch360: renderer C, the 360 projection drawn by the plugin
// (IMMUCH360-NOTE.md, patch 6).
//
// Why it exists: the 360 view as an mpv user shader (renderer A) changes the
// view through glsl-shader-opts, and every change rebuilds mpv's passes. On
// 2026-10-09 that kept 40 to 200 MB of GPU memory per change on an RTX 4060
// until the PC ran out of memory, and gave 11 fps on an Intel UHD (spikes 3 and
// 4, builds/desktop/p2b). Here mpv only draws the frame, as it does for a flat
// video, into an intermediate texture of the video's size (capped by the tier
// the app chose); the view is drawn from it by one pass of the plugin, whose
// uniforms change without touching mpv, and a paused video is redrawn from the
// texture kept without calling mpv at all.
//
// Everything here runs on the one worker thread of |VideoOutputManager|, with
// the context of the player's |ANGLESurfaceManager| current.

#ifndef PROJECTION_RENDERER_H_
#define PROJECTION_RENDERER_H_

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <cstdint>
#include <map>
#include <string>
#include <vector>

// What a player shows through renderer C, as Dart gives it
// (lib/src/projection_output.dart).
struct ProjectionSetup {
  // 0 an equirectangular frame, 1 a fisheye pair, 2 a GoPro EAC pair
  int32_t kind = 0;
  // Equirectangular: the eye shown, in fractions of the frame (x, y, width,
  // height, top left origin), and the part of the sphere it covers
  float eye[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  float crop[4] = {0.0f, 0.0f, 1.0f, 1.0f};
  // Stitches: the streams side by side in the frame, which are decoded, and
  // the uniforms of the lenses or faces by name
  int32_t tracks = 1;
  float enabled[2] = {1.0f, 1.0f};
  std::map<std::string, std::vector<float>> uniforms;
  // The tier: the intermediate texture keeps the video's shape, at most this
  // wide and this many pixels
  int32_t max_frame_width = 8192;
  int64_t max_frame_pixels = 8192LL * 4096LL;
  // The output in physical pixels, at most |max_output_height| lines (the
  // window's shape kept), from its first frame (design 2.11)
  int32_t output_width = 1;
  int32_t output_height = 1;
  int32_t max_output_height = 1440;

  // The output size once capped, each side at least 1 and even
  void OutputSize(int32_t* width, int32_t* height) const;

  // Whether |other| reads the frame the same way: the kind, the streams and
  // the uniforms of the lenses or faces. The eye and the part of the sphere
  // may differ: the 3D cycle and the 180 and 360 switch change only them.
  bool SameFrameLayout(const ProjectionSetup& other) const;
};

// The view: yaw and pitch in degrees (yaw positive to the right of the
// frame's centre, pitch positive up), the vertical field of view in degrees,
// and whether it rests (the sharper filter) or moves (bilinear).
struct ProjectionView {
  float yaw = 0.0f;
  float pitch = 0.0f;
  float fov = 90.0f;
  bool sharp = true;
};

class ProjectionRenderer {
 public:
  ProjectionRenderer() = default;
  ~ProjectionRenderer() = default;

  // Loads the OpenGL ES 3.0 entry points and makes the vertex array; false
  // (with |error|) on an ES 2.0 context or a driver without them.
  bool Prepare(int32_t client_version);

  // Compiles and links the pass of |kind| now rather than at the first frame;
  // false with |error| (the shader's or the program's log) when the driver
  // refuses it, kept until |Release|.
  bool PrepareProgram(int32_t kind) { return Program(kind) != 0; }

  // The intermediate texture and its FBO for a video of |video_width| x
  // |video_height| under |setup|'s tier, made again only when that size
  // changes. False when no FBO could be made.
  bool EnsureFrame(int64_t video_width,
                   int64_t video_height,
                   const ProjectionSetup& setup);

  GLuint frame_fbo() const { return frame_fbo_; }
  int32_t frame_width() const { return frame_width_; }
  int32_t frame_height() const { return frame_height_; }

  // Whether the intermediate texture holds a frame of the current video: a
  // view is drawn only from a frame mpv drew.
  bool has_frame() const { return has_frame_; }
  void set_has_frame(bool value) { has_frame_ = value; }

  // Draws the view into the bound surface (FBO 0) at |width| x |height|, then
  // leaves the OpenGL state at the defaults mpv expects (render_gl.h).
  bool DrawView(const ProjectionSetup& setup,
                const ProjectionView& view,
                int32_t width,
                int32_t height);

  // Reads five pixels of the output just drawn: the centre, then the middle
  // of the top, bottom, left and right edges (an eighth inside), as 0xAABBGGRR.
  void ReadProbe(int32_t width, int32_t height, uint32_t out[5]);

  // Deletes every OpenGL object; the context must be current.
  void Release();

  const std::string& error() const { return error_; }
  const std::string& gl_renderer() const { return gl_renderer_; }

 private:
  GLuint Program(int32_t kind);
  GLuint Compile(GLenum type, const std::string& source);
  void SetUniforms(GLuint program,
                   const ProjectionSetup& setup,
                   const ProjectionView& view,
                   int32_t width,
                   int32_t height);

  using TexStorage2D = void(GL_APIENTRY*)(GLenum, GLsizei, GLenum, GLsizei,
                                          GLsizei);
  using GenVertexArrays = void(GL_APIENTRY*)(GLsizei, GLuint*);
  using BindVertexArray = void(GL_APIENTRY*)(GLuint);
  using DeleteVertexArrays = void(GL_APIENTRY*)(GLsizei, const GLuint*);
  using BindSampler = void(GL_APIENTRY*)(GLuint, GLuint);

  TexStorage2D tex_storage_2d_ = nullptr;
  GenVertexArrays gen_vertex_arrays_ = nullptr;
  BindVertexArray bind_vertex_array_ = nullptr;
  DeleteVertexArrays delete_vertex_arrays_ = nullptr;
  BindSampler bind_sampler_ = nullptr;

  bool prepared_ = false;
  GLuint vertex_array_ = 0;
  GLuint vertex_shader_ = 0;
  GLuint programs_[3] = {0, 0, 0};
  bool program_failed_[3] = {false, false, false};
  GLuint frame_texture_ = 0;
  GLuint frame_fbo_ = 0;
  int32_t frame_width_ = 0;
  int32_t frame_height_ = 0;
  bool has_frame_ = false;
  std::string error_;
  std::string gl_renderer_;
};

#endif  // PROJECTION_RENDERER_H_
