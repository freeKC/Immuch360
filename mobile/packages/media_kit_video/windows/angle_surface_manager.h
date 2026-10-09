// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef ANGLE_SURFACE_MANAGER_H_
#define ANGLE_SURFACE_MANAGER_H_

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglplatform.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <Windows.h>

#include <d3d.h>
#include <d3d11.h>
#include <wrl.h>

#include "utils.h"

#include <cstdint>
#include <functional>

// Immuch360: EGL_OPENGL_ES3_BIT_KHR of EGL_KHR_create_context (EGL 1.5 names it
// EGL_OPENGL_ES3_BIT), defined here so that the build does not depend on the
// version of the ANGLE headers the libs package downloads.
#ifdef EGL_OPENGL_ES3_BIT_KHR
#define IMMUCH360_EGL_OPENGL_ES3_BIT EGL_OPENGL_ES3_BIT_KHR
#else
#define IMMUCH360_EGL_OPENGL_ES3_BIT 0x00000040
#endif

// |ANGLESurfaceManager| provides an abstraction around ANGLE to easily draw
// OpenGL ES 2.0 content & read as D3D 11 texture using shared |HANDLE|.
// * |Draw|: Takes callback where OpenGL ES 2.0 calls can be made for rendering.
// * |Read|: Copies the drawn content to D3D 11 texture & makes it available to
//           the shared |handle| for access.

// A large part of implementation is inspired from Flutter.
// https://github.com/flutter/engine/blob/master/shell/platform/windows/angle_surface_manager.h

class ANGLESurfaceManager {
 public:
  const int32_t width() const { return width_; }
  const int32_t height() const { return height_; }
  const HANDLE handle() const { return handle_; }

  ANGLESurfaceManager(int32_t width, int32_t height);

  ~ANGLESurfaceManager();

  void SetSize(int32_t width, int32_t height);

  void Draw(std::function<void()> callback);

  void Read();

  void MakeCurrent(bool value);

  // Immuch360: the OpenGL ES major version of |context_| (3, or 2 when the
  // device or the display could not give 3), for the logs and the probes.
  const int32_t client_version() const { return client_version_; }

  // Immuch360: whether the Direct3D 11 device was removed (a driver update or
  // reset, a GPU switched or gone): nothing drawn or made on it shows any more,
  // and only a new surface manager, on a new device, does (IMMUCH360-NOTE.md,
  // patch 4).
  bool IsDeviceLost() const;

 private:
  // Immuch360: chooses |config_| and creates |context_| for |client_version|.
  bool CreateContext(int32_t client_version);

  void SwapBuffers();

  void Create();

  void CleanUp(bool release_context);

  bool CreateD3DTexture();

  bool CreateEGLDisplay();

  bool CreateAndBindEGLSurface();

  int32_t width_ = 1;
  int32_t height_ = 1;
  HANDLE internal_handle_ = nullptr;
  HANDLE handle_ = nullptr;

  // Sync |Draw| & |Read| calls.
  HANDLE mutex_ = nullptr;
  // D3D 11
  ID3D11Device* d3d_11_device_ = nullptr;
  ID3D11DeviceContext* d3d_11_device_context_ = nullptr;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> internal_d3d_11_texture_2D_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> d3d_11_texture_2D_;
  // ANGLE
  EGLSurface surface_ = EGL_NO_SURFACE;
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = nullptr;
  EGLConfig config_ = nullptr;
  int32_t client_version_ = 0;

  static constexpr EGLint kEGLConfigurationAttributes[] = {
      EGL_RED_SIZE,   8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE,    8,
      EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 8, EGL_STENCIL_SIZE, 8,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributes[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      2,
      EGL_NONE,
  };
  // Immuch360: an OpenGL ES 3.0 context first. In ES 2.0 mpv runs GLSL ES 1.00
  // and may render in an 8 bit FBO (rgba8 is the last format it tries), which
  // bands; in ES 3.0 it gets GLSL ES 3.00, which the 360 and Spatial shaders
  // want, and an rgba16f FBO. The context does not bring zero copy decoding:
  // mpv 0.39's d3d11egl interop also asks the display for EGL_EXT_device_query,
  // which this ANGLE lists as a client extension only, so the decoder frames
  // are copied back in either version (IMMUCH360-NOTE.md, patch 1). ANGLE
  // implements ES 3.0 over Direct3D 11 at feature level 10_0 and above; the
  // ES 2.0 attributes above stay the fallback for the 9_3 and Direct3D 9
  // displays.
  static constexpr EGLint kEGLConfigurationAttributesES3[] = {
      EGL_RED_SIZE,        8,
      EGL_GREEN_SIZE,      8,
      EGL_BLUE_SIZE,       8,
      EGL_ALPHA_SIZE,      8,
      EGL_DEPTH_SIZE,      8,
      EGL_STENCIL_SIZE,    8,
      EGL_RENDERABLE_TYPE, IMMUCH360_EGL_OPENGL_ES3_BIT,
      EGL_NONE,
  };
  static constexpr EGLint kEGLContextAttributesES3[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      3,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D11_9_3DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MAJOR_ANGLE,
      9,
      EGL_PLATFORM_ANGLE_MAX_VERSION_MINOR_ANGLE,
      3,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };
  static constexpr EGLint kD3D9DisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
      EGL_NONE,
  };
  static constexpr EGLint kWrapDisplayAttributes[] = {
      EGL_PLATFORM_ANGLE_TYPE_ANGLE,
      EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
      EGL_PLATFORM_ANGLE_ENABLE_AUTOMATIC_TRIM_ANGLE,
      EGL_TRUE,
      EGL_NONE,
  };

  // Number of active instances of ANGLESurfaceManager.
  static int32_t instance_count_;
};

#endif  // ANGLE_SURFACE_MANAGER_H_
