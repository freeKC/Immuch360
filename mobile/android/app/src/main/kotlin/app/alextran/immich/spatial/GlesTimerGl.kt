package app.alextran.immich.spatial

import android.opengl.GLES30

/**
 * [TimerGl] on OpenGL ES 3.0 with GL_EXT_disjoint_timer_query. The only file of the app that calls the query
 * functions: GpuFrameTimer decides when, and only on the drivers GpuTimerPolicy allows.
 */
internal class GlesTimerGl : TimerGl {
  private companion object {
    /** GL_EXT_disjoint_timer_query */
    const val GL_TIME_ELAPSED_EXT = 0x88BF
    const val GL_GPU_DISJOINT_EXT = 0x8FBB
  }

  private val value = IntArray(1)

  override fun genQueries(ids: IntArray) = GLES30.glGenQueries(ids.size, ids, 0)

  override fun deleteQueries(ids: IntArray) = GLES30.glDeleteQueries(ids.size, ids, 0)

  override fun beginQuery(id: Int) = GLES30.glBeginQuery(GL_TIME_ELAPSED_EXT, id)

  override fun endQuery() = GLES30.glEndQuery(GL_TIME_ELAPSED_EXT)

  override fun resultAvailable(id: Int): Boolean {
    GLES30.glGetQueryObjectuiv(id, GLES30.GL_QUERY_RESULT_AVAILABLE, value, 0)
    return value[0] != 0
  }

  override fun result(id: Int): Long {
    GLES30.glGetQueryObjectuiv(id, GLES30.GL_QUERY_RESULT, value, 0)
    return value[0].toLong() and 0xffffffffL
  }

  override fun disjoint(): Boolean {
    GLES30.glGetIntegerv(GL_GPU_DISJOINT_EXT, value, 0)
    return value[0] != 0
  }

  override fun finish() = GLES30.glFinish()

  override fun error(): Int = GLES30.glGetError()
}
