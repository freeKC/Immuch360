package app.alextran.immich.spatial

import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.util.Log

/**
 * Small OpenGL ES 3.0 helpers of the Spatial 2.5D renderer: compile and link programs, create textures and
 * framebuffers, check errors. Every function must run on the GL thread, with the renderer's context current.
 */
internal object SpatialGl {
  const val TAG = "Immuch360"

  /** Compiles one shader stage, returns 0 and logs the compiler output when it fails */
  fun compileShader(type: Int, source: String, name: String): Int {
    val shader = GLES30.glCreateShader(type)
    if (shader == 0) {
      Log.e(TAG, "Cannot create the shader $name")
      return 0
    }
    GLES30.glShaderSource(shader, source)
    GLES30.glCompileShader(shader)
    val status = IntArray(1)
    GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
    if (status[0] == 0) {
      Log.e(TAG, "Cannot compile the shader $name: ${GLES30.glGetShaderInfoLog(shader)}")
      GLES30.glDeleteShader(shader)
      return 0
    }
    return shader
  }

  /**
   * Compiles and links a program, returns null and logs the reason when it fails. The vertex [attributes], if any,
   * get the locations 0, 1 and so on, in order.
   */
  fun linkProgram(
    vertexSource: String,
    fragmentSource: String,
    name: String,
    attributes: Array<String> = emptyArray(),
  ): GlProgram? {
    val vertex = compileShader(GLES30.GL_VERTEX_SHADER, vertexSource, "$name (vertex)")
    if (vertex == 0) return null
    val fragment = compileShader(GLES30.GL_FRAGMENT_SHADER, fragmentSource, "$name (fragment)")
    if (fragment == 0) {
      GLES30.glDeleteShader(vertex)
      return null
    }
    val program = GLES30.glCreateProgram()
    if (program == 0) {
      Log.e(TAG, "Cannot create the program $name")
      GLES30.glDeleteShader(vertex)
      GLES30.glDeleteShader(fragment)
      return null
    }
    GLES30.glAttachShader(program, vertex)
    GLES30.glAttachShader(program, fragment)
    attributes.forEachIndexed { location, attribute -> GLES30.glBindAttribLocation(program, location, attribute) }
    GLES30.glLinkProgram(program)
    // The program keeps the compiled stages alive as long as it needs them
    GLES30.glDeleteShader(vertex)
    GLES30.glDeleteShader(fragment)
    val status = IntArray(1)
    GLES30.glGetProgramiv(program, GLES30.GL_LINK_STATUS, status, 0)
    if (status[0] == 0) {
      Log.e(TAG, "Cannot link the program $name: ${GLES30.glGetProgramInfoLog(program)}")
      GLES30.glDeleteProgram(program)
      return null
    }
    return GlProgram(program, name)
  }

  /** Creates a 2D texture of [width] x [height] with clamped edges, returns 0 when it fails */
  fun createTexture(width: Int, height: Int, internalFormat: Int, format: Int, type: Int, filter: Int): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    val texture = ids[0]
    if (texture == 0) return 0
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, filter)
    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, filter)
    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, internalFormat, width, height, 0, format, type, null)
    GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)
    if (checkError("create a $width x $height texture")) {
      GLES30.glDeleteTextures(1, ids, 0)
      return 0
    }
    return texture
  }

  /** Creates the external texture the video decoder draws into through a SurfaceTexture */
  fun createExternalTexture(): Int {
    val ids = IntArray(1)
    GLES30.glGenTextures(1, ids, 0)
    val texture = ids[0]
    if (texture == 0) return 0
    val target = GLES11Ext.GL_TEXTURE_EXTERNAL_OES
    GLES30.glBindTexture(target, texture)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glTexParameteri(target, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
    GLES30.glBindTexture(target, 0)
    if (checkError("create the video texture")) {
      GLES30.glDeleteTextures(1, ids, 0)
      return 0
    }
    return texture
  }

  /** Creates a framebuffer drawing into [texture], returns 0 when the driver cannot render into it */
  fun createFramebuffer(texture: Int): Int {
    val ids = IntArray(1)
    GLES30.glGenFramebuffers(1, ids, 0)
    val framebuffer = ids[0]
    if (framebuffer == 0) return 0
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
    GLES30.glFramebufferTexture2D(
      GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, texture, 0,
    )
    val status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
    if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
      Log.w(TAG, "Framebuffer incomplete, status 0x${Integer.toHexString(status)}")
      GLES30.glDeleteFramebuffers(1, ids, 0)
      return 0
    }
    return framebuffer
  }

  /** Creates a texture and a framebuffer drawing into it, returns null when either fails */
  fun createTarget(width: Int, height: Int, format: TargetFormat, filter: Int): GlTarget? {
    if (width <= 0 || height <= 0) return null
    val texture = createTexture(width, height, format.internalFormat, format.format, format.type, filter)
    if (texture == 0) return null
    val framebuffer = createFramebuffer(texture)
    if (framebuffer == 0) {
      deleteTexture(texture)
      return null
    }
    return GlTarget(width, height, texture, framebuffer)
  }

  fun deleteTexture(texture: Int) {
    if (texture != 0) GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
  }

  /** Logs every pending GL error, returns true when there was one */
  fun checkError(what: String): Boolean {
    var failed = false
    while (true) {
      val error = GLES30.glGetError()
      if (error == GLES30.GL_NO_ERROR) break
      Log.e(TAG, "GL error 0x${Integer.toHexString(error)} while trying to $what")
      failed = true
    }
    return failed
  }

  /** Discards the pending GL errors without logging them */
  fun clearErrors() {
    while (GLES30.glGetError() != GLES30.GL_NO_ERROR) {
      // Nothing to do, the loop only drains the error flags
    }
  }

  /** True when the current context lists the extension [name] */
  fun hasExtension(name: String): Boolean {
    val extensions = GLES30.glGetString(GLES30.GL_EXTENSIONS) ?: return false
    return extensions.split(' ').contains(name)
  }
}

/** Storage of a render target: the internal format, the pixel format and the pixel type of glTexImage2D */
internal enum class TargetFormat(val internalFormat: Int, val format: Int, val type: Int) {
  RGBA8(GLES30.GL_RGBA8, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE),
  RGBA16F(GLES30.GL_RGBA16F, GLES30.GL_RGBA, GLES30.GL_HALF_FLOAT),
}

/** A linked program, with a cache of its uniform locations */
internal class GlProgram(val id: Int, val name: String) {
  private val locations = HashMap<String, Int>()

  fun use() = GLES30.glUseProgram(id)

  /** Location of the uniform [uniform], -1 when the compiler removed it (GL ignores writes to -1) */
  fun location(uniform: String): Int = locations.getOrPut(uniform) { GLES30.glGetUniformLocation(id, uniform) }

  fun setInt(uniform: String, value: Int) = GLES30.glUniform1i(location(uniform), value)

  fun setFloat(uniform: String, value: Float) = GLES30.glUniform1f(location(uniform), value)

  fun setVec2(uniform: String, x: Float, y: Float) = GLES30.glUniform2f(location(uniform), x, y)

  fun setVec4(uniform: String, x: Float, y: Float, z: Float, w: Float) =
    GLES30.glUniform4f(location(uniform), x, y, z, w)

  fun setIVec2(uniform: String, x: Int, y: Int) = GLES30.glUniform2i(location(uniform), x, y)

  fun setMat3(uniform: String, columns: FloatArray) = GLES30.glUniformMatrix3fv(location(uniform), 1, false, columns, 0)

  fun setMat4(uniform: String, columns: FloatArray) = GLES30.glUniformMatrix4fv(location(uniform), 1, false, columns, 0)

  fun release() = GLES30.glDeleteProgram(id)
}

/** A texture with a framebuffer that draws into it */
internal class GlTarget(val width: Int, val height: Int, val texture: Int, val framebuffer: Int) {
  /** Draws the next passes into this target, over its whole size */
  fun bind() {
    GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, framebuffer)
    GLES30.glViewport(0, 0, width, height)
  }

  fun release() {
    GLES30.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
    GLES30.glDeleteTextures(1, intArrayOf(texture), 0)
  }
}
