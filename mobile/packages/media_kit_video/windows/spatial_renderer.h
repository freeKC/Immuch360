// Immuch360: the Spatial 2.5D passes in renderer C (IMMUCH360-NOTE.md, patch
// 11).
//
// What it does: a stereo video (two eyes side by side or top and bottom, flat
// or equirectangular) is shown from a viewpoint between its two cameras, which
// the head of the person in front of the screen moves. It is the renderer of
// the phones (SpatialRenderer.kt, with SpatialShaders.kt) moved into the plugin:
// mpv draws each frame into renderer C's intermediate texture, as for a 360
// video, and these passes draw the view from it into the player's texture:
// 1. each eye into its own texture (an equirectangular eye through renderer C's
//    own equirectangular pass, at the view Dart sets),
// 2. both eyes in grey at the disparity size,
// 3. block matching both ways, the left right check and the temporal blend
//    with the previous map, kept in a ping pong pair,
// 4. a blur of the map,
// 5. the synthesis at the viewpoint p.
// Passes 2 to 4 run every few new frames as the tier says, and a few more times
// once the eyes stop changing, to settle. The tiers, their adaptive rule and
// the settling are those of SpatialRenderer.kt, measured here as there.
//
// Everything here runs on the one worker thread of |VideoOutputManager|, with
// the context of the player's |ANGLESurfaceManager| current.

#ifndef SPATIAL_RENDERER_H_
#define SPATIAL_RENDERER_H_

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <array>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "projection_renderer.h"

// What the Spatial passes did, the figures of the last second as
// SpatialRenderer.kt's SpatialStats gives them, and counts since the last read
struct SpatialCounters {
  float render_fps = 0.0f;
  float disparity_fps = 0.0f;
  float render_ms = 0.0f;
  int32_t disparity_width = 0;
  int32_t disparity_height = 0;
  int32_t eye_width = 0;
  int32_t eye_height = 0;
  int32_t quality = 1;
  float viewpoint = 0.5f;
  bool stereo = false;
  int64_t draws = 0;
  int64_t disparity_runs = 0;
  int64_t settle_runs = 0;
  int64_t quality_changes = 0;
  bool gpu_timer = false;
  bool half_float_maps = false;
};

class SpatialRenderer {
 public:
  // The input of one draw
  struct Input {
    // Renderer C's intermediate texture (the frame mpv drew) and its size
    GLuint frame_texture = 0;
    int32_t frame_width = 0;
    int32_t frame_height = 0;
    // Whether mpv drew a new frame into it for this draw
    bool new_frame = false;
    // 0 the left camera, 0.5 between the cameras, 1 the right camera
    float viewpoint = 0.5f;
    // The view of an equirectangular eye (renderer C's convention)
    ProjectionView view;
    // The disparity map instead of the synthesis (troubleshooting)
    bool show_disparity = false;
    // The output: the bound surface (FBO 0) at this size
    int32_t width = 1;
    int32_t height = 1;
    // Steady clock, nanoseconds
    int64_t now_ns = 0;
  };

  SpatialRenderer() = default;
  ~SpatialRenderer() = default;

  // Loads the OpenGL ES 3.0 entry points, makes the vertex array, picks the
  // format of the maps and whether GPU timers exist; false (with |error|) on an
  // ES 2.0 context or a driver without them.
  bool Prepare(int32_t client_version);

  // Compiles and links every program now rather than at the first frame; false
  // with |error| (the shader's or the program's log) when the driver refuses
  // one. The disparity pass, with its loops, is the slow one to compile.
  bool PreparePrograms();

  // The size of the output of a flat |setup| inside the box Dart gives: the
  // shape of one eye as it shows (a squeezed stereo frame shows its eyes at the
  // frame's shape), each side at least 2 and even. The box itself while the
  // video's size is not known, and for an equirectangular setup.
  static void OutputSize(const SpatialSetup& setup,
                         int64_t video_width,
                         int64_t video_height,
                         int32_t box_width,
                         int32_t box_height,
                         int32_t* width,
                         int32_t* height);

  // Draws the view into the bound surface (FBO 0) at the size of |input|, then
  // leaves the OpenGL state at the defaults mpv expects (render_gl.h). False
  // when nothing could be drawn (no frame, or no program).
  bool Draw(const SpatialSetup& setup, const Input& input);

  // When passes 2 to 4 want to run again on the same eyes to settle (steady
  // clock, nanoseconds), 0 once they have settled.
  int64_t NextSettleNs() const;
  bool SettleDue(int64_t now_ns) const {
    const auto next = NextSettleNs();
    return next > 0 && now_ns >= next;
  }

  // The middle row of the output just drawn, as 0xAABBGGRR from left to right.
  void ReadRow(int32_t width, int32_t height, std::vector<uint32_t>* row);

  // The counters, the counts since the last call set back to 0.
  SpatialCounters TakeCounters();

  // Deletes every OpenGL object; the context must be current.
  void Release();

  const std::string& error() const { return error_; }

 private:
  // A texture with a framebuffer that draws into it (SpatialGl.kt's GlTarget)
  struct Target {
    GLuint texture = 0;
    GLuint framebuffer = 0;
    int32_t width = 0;
    int32_t height = 0;
    bool valid() const { return framebuffer != 0; }
    void Bind() const;
  };

  // A linked program with its uniform locations
  struct Program {
    GLuint id = 0;
    std::unordered_map<std::string, GLint> locations;
    GLint At(const char* name);
  };

  // The disparity resolution of a tier (for a 16:9 eye), how many changed
  // frames between two estimations, and the left right check
  struct Tier {
    int32_t width;
    int32_t height;
    int32_t interval;
    bool consistency_check;
  };
  static Tier TierOf(int32_t quality);

  enum class Format { kRgba8, kRgba16f };

  GLuint Compile(GLenum type, const std::string& source, const char* name);
  bool Link(Program* program,
            const std::string& vertex,
            const std::string& fragment,
            const char* name);
  Target CreateTarget(int32_t width, int32_t height, Format format,
                      GLint filter);
  void DeleteTarget(Target* target);
  Format PickMapFormat();

  void DrawTriangle();
  void BindTexture(int unit, GLuint texture);
  void BeginScreen();

  float EyeDisplayAspect(const SpatialSetup& setup) const;
  bool UpdateGeometry(const SpatialSetup& setup);
  void UseEyeProgram(const SpatialSetup& setup, const Input& input,
                     float aspect, Program** used);
  void SetEyeRect(Program* program, const SpatialSetup& setup,
                  const float rect[4]);
  bool RenderEyes(const SpatialSetup& setup, const Input& input, bool stereo);
  void DrawEyeDirect(const SpatialSetup& setup, const Input& input);
  void DrawCopy(const Target& eye);

  int32_t SearchRange() const;
  float EncodeScale() const;
  bool EnsureDisparityTargets(int32_t quality);
  bool ViewChangedSinceMap(const SpatialSetup& setup) const;
  void ComputeDisparity(const Tier& tier, bool fresh_view);
  void DrawSynthesis(const Tier& tier, float viewpoint);
  void DrawDisparity();

  void BeginGpuTimer();
  void EndGpuTimer();
  void CollectGpuTimers();
  void AddTimingSample(float milliseconds);
  void UpdateStatistics(int64_t now_ns);
  void Adapt(float average_ms, bool estimated, int64_t now_ns);
  void BlockStepUp(int32_t quality, int64_t until_ns);

  void ReleaseEyeTargets();
  void ReleaseDisparityTargets();
  void ResetState();

  // OpenGL ES 3.0 entry points the ES 2.0 headers of the libs package do not
  // declare
  using GenVertexArrays = void(GL_APIENTRY*)(GLsizei, GLuint*);
  using BindVertexArray = void(GL_APIENTRY*)(GLuint);
  using DeleteVertexArrays = void(GL_APIENTRY*)(GLsizei, const GLuint*);
  using GenSamplers = void(GL_APIENTRY*)(GLsizei, GLuint*);
  using DeleteSamplers = void(GL_APIENTRY*)(GLsizei, const GLuint*);
  using BindSampler = void(GL_APIENTRY*)(GLuint, GLuint);
  using SamplerParameteri = void(GL_APIENTRY*)(GLuint, GLenum, GLint);
  using GenQueries = void(GL_APIENTRY*)(GLsizei, GLuint*);
  using DeleteQueries = void(GL_APIENTRY*)(GLsizei, const GLuint*);
  using BeginQuery = void(GL_APIENTRY*)(GLenum, GLuint);
  using EndQuery = void(GL_APIENTRY*)(GLenum);
  using GetQueryObjectuiv = void(GL_APIENTRY*)(GLuint, GLenum, GLuint*);

  GenVertexArrays gen_vertex_arrays_ = nullptr;
  BindVertexArray bind_vertex_array_ = nullptr;
  DeleteVertexArrays delete_vertex_arrays_ = nullptr;
  GenSamplers gen_samplers_ = nullptr;
  DeleteSamplers delete_samplers_ = nullptr;
  BindSampler bind_sampler_ = nullptr;
  SamplerParameteri sampler_parameteri_ = nullptr;
  GenQueries gen_queries_ = nullptr;
  DeleteQueries delete_queries_ = nullptr;
  BeginQuery begin_query_ = nullptr;
  EndQuery end_query_ = nullptr;
  GetQueryObjectuiv get_query_objectuiv_ = nullptr;

  bool prepared_ = false;
  bool programs_ready_ = false;
  std::string error_;
  GLuint vertex_array_ = 0;
  // The flat eye reads the intermediate texture with clamped edges, where
  // renderer C repeats them for the seam of a 360 frame
  GLuint clamp_sampler_ = 0;
  Format map_format_ = Format::kRgba8;

  Program eye_flat_;
  Program eye_sphere_;
  Program copy_;
  Program gray_;
  Program disparity_;
  Program blend_;
  Program blur_;
  Program synthesis_program_;
  Program show_disparity_;

  // The output rectangle (the eye's shape, letterboxed in the output while
  // the output has another shape) and the size of the output
  int32_t view_width_ = 0;
  int32_t view_height_ = 0;
  int32_t out_x_ = 0;
  int32_t out_y_ = 0;
  int32_t out_width_ = 0;
  int32_t out_height_ = 0;
  // The frame of the current draw, for the eye's shape
  int32_t frame_width_ = 0;
  int32_t frame_height_ = 0;
  // tan of half the vertical field of view of the equirectangular eye pass
  double eye_tan_half_ = 1.0;

  // Eye textures at the output size, capped; the synthesis target when the
  // output is larger than the eyes
  Target left_eye_;
  Target right_eye_;
  Target synthesis_;
  bool eye_targets_failed_ = false;
  bool eyes_valid_ = false;
  int32_t last_layout_ = -1;
  int32_t last_projection_ = -1;
  int last_half_sphere_ = -1;
  float last_yaw_ = 0.0f;
  float last_pitch_ = 0.0f;
  float last_fov_ = 0.0f;
  bool last_sharp_ = false;
  bool has_last_view_ = false;

  // Disparity targets at the resolution of the active tier
  int32_t active_quality_ = -1;
  int32_t disparity_width_ = 0;
  int32_t disparity_height_ = 0;
  bool disparity_failed_ = false;
  Target gray_left_;
  Target gray_right_;
  Target raw_left_;
  Target raw_right_;
  Target maps_[2];
  int current_map_ = 0;
  Target blur_temp_;
  Target blurred_;
  bool map_empty_ = true;
  bool map_reset_ = true;
  // The view the current map was computed for (equirectangular only)
  bool has_map_view_ = false;
  float map_yaw_ = 0.0f;
  float map_pitch_ = 0.0f;
  float map_fov_ = 0.0f;
  int32_t changes_since_disparity_ = 0;
  int64_t last_eye_change_ns_ = 0;
  int64_t last_draw_ns_ = 0;
  int32_t settle_runs_ = 0;
  bool stereo_ = false;

  // The tier: the one Dart asked for last, the current one, and the adaptive
  // rule's state
  int32_t requested_quality_ = -1;
  int32_t quality_ = 1;
  bool adaptive_ = true;

  // Timing
  bool timer_supported_ = false;
  bool timer_checked_ = false;
  std::array<GLuint, 4> queries_ = {0, 0, 0, 0};
  std::array<bool, 4> query_pending_ = {false, false, false, false};
  int next_query_ = 0;
  int active_query_ = -1;
  int64_t cpu_timing_start_ns_ = 0;
  int64_t frame_count_ = 0;
  int64_t window_start_ns_ = 0;
  int32_t frames_in_window_ = 0;
  int32_t disparity_runs_in_window_ = 0;
  int32_t spatial_frames_in_window_ = 0;
  float timing_sum_ = 0.0f;
  int32_t timing_count_ = 0;
  int32_t fast_seconds_ = 0;
  int32_t warmup_windows_ = 1;
  std::array<int64_t, 3> step_up_blocked_until_ = {INT64_MIN, INT64_MIN,
                                                   INT64_MIN};

  // Statistics of the last second, and counts since the last read
  SpatialCounters counters_;
};

#endif  // SPATIAL_RENDERER_H_
