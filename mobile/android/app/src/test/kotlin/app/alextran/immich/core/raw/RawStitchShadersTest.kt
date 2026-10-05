package app.alextran.immich.core.raw

import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The GLSL of every variant: each uniform the Kotlin side sets is declared, nothing is left unresolved, and, when
 * glslangValidator is installed (on the PATH, or named by GLSLANG_VALIDATOR), every source compiles.
 */
class RawStitchShadersTest {
  private val toneMaps = RawStitchShaders.ToneMap.entries
  private val colors =
    listOf(RawStitchShaders.Color.SDR) +
      toneMaps.filter { it != RawStitchShaders.ToneMap.NONE }.flatMap { tone ->
        listOf(RawStitchShaders.Color(yuv = true, toneMap = tone), RawStitchShaders.Color(yuv = false, toneMap = tone))
      }

  private val uniformDeclaration = Regex("""uniform\s+(?:(?:highp|mediump|lowp)\s+)?\w+\s+(\w+)\s*;""")

  private fun declared(source: String): Set<String> =
    uniformDeclaration.findAll(source).map { it.groupValues[1] }.toSet()

  private val allNames =
    RawStitchShaders.COMMON_UNIFORMS + RawStitchShaders.YUV_UNIFORMS + RawStitchShaders.FISHEYE_UNIFORMS +
      RawStitchShaders.EAC_UNIFORMS + RawStitchShaders.SIDE_BY_SIDE_UNIFORMS + RawStitchShaders.OUTPUT_SIZE_UNIFORM

  @Test
  fun `every variant declares the uniforms the compositor sets and no others`() {
    for (kind in RawKind.entries) {
      for (color in colors) {
        val source = RawStitchShaders.fragmentEs3(kind, color)
        val names = declared(source)
        for (name in RawStitchShaders.uniformsOf(kind, color)) assertTrue("$kind ${color.label}: $name", name in names)
        for (name in names) assertTrue("$kind ${color.label}: $name is not in a list", name in allNames)
      }
    }
    val sideBySide = declared(RawStitchShaders.fragmentEs1SideBySide())
    assertEquals(RawStitchShaders.SIDE_BY_SIDE_UNIFORMS.toSet(), sideBySide)
  }

  @Test
  fun `every uniform the uniform builders produce is declared`() {
    val b = RawProjection.parse(RawFixtures.B)
    val fisheye = RawStitchUniforms.fisheye(b).keys + RawStitchUniforms.halfTexels(b, listOf(null, null)).keys
    assertTrue(RawStitchShaders.FISHEYE_UNIFORMS.containsAll(fisheye))
    val eac = RawStitchUniforms.eac(RawProjection.parse(RawFixtures.E)).keys
    assertTrue(RawStitchShaders.EAC_UNIFORMS.containsAll(eac))
  }

  @Test
  fun `the sources hold no unresolved template nor a stray value`() {
    val sources =
      RawKind.entries.flatMap { kind -> colors.map { RawStitchShaders.fragmentEs3(kind, it) } } +
        RawStitchShaders.fragmentEs1SideBySide() + RawStitchShaders.vertexEs3() + RawStitchShaders.vertexEs1()
    for (source in sources) {
      assertFalse(source.contains("$"))
      assertFalse(source.contains("null"))
      assertFalse(source.contains("NaN"))
    }
  }

  @Test
  fun `the variants define what they read`() {
    val hlgYuv =
      RawStitchShaders.fragmentEs3(RawKind.DUAL_FISHEYE, RawStitchShaders.Color(true, RawStitchShaders.ToneMap.HLG))
    assertTrue(hlgYuv.contains("#extension GL_EXT_YUV_target : require"))
    assertTrue(hlgYuv.contains("#define YUV_INPUT"))
    assertTrue(hlgYuv.contains("#define TONE_MAP_HLG"))
    val pqRgb =
      RawStitchShaders.fragmentEs3(RawKind.EAC_GOPRO, RawStitchShaders.Color(false, RawStitchShaders.ToneMap.PQ))
    assertFalse(pqRgb.contains("GL_EXT_YUV_target"))
    assertTrue(pqRgb.contains("#define TONE_MAP_PQ"))
    assertTrue(pqRgb.contains("stitchEac(viewDirection(vOut))"))
    val oldDriver =
      RawStitchShaders.fragmentEs3(RawKind.DUAL_FISHEYE, RawStitchShaders.Color.SDR, essl3External = false)
    assertTrue(oldDriver.contains("#extension GL_OES_EGL_image_external : require"))
    // The tone map constants are HdrToneMap's
    assertTrue(hlgYuv.contains("const float KNEE = 0.8;"))
    val columns = "mat3(1.6605, -0.1246, -0.0182, -0.5876, 1.1329, -0.1006, -0.0728, -0.0083, 1.1187)"
    assertTrue(hlgYuv.contains(columns))
  }

  @Test
  fun `glslangValidator compiles every source`() {
    val validator = glslangValidator()
    assumeTrue("glslangValidator is not installed: shaders not compiled here", validator != null)
    val directory = createTempDirectory()
    try {
      val sources = mutableMapOf<String, String>()
      sources["compositor.vert"] = RawStitchShaders.vertexEs3()
      sources["effect.vert"] = RawStitchShaders.vertexEs1()
      sources["effect.frag"] = RawStitchShaders.fragmentEs1SideBySide()
      for (kind in RawKind.entries) {
        for (color in colors) {
          // The reference compiler takes the ES 3 external sampler extension only (drivers take both)
          sources["${kind.name.lowercase()}_${color.label.replace(' ', '_').lowercase()}.frag"] =
            RawStitchShaders.fragmentEs3(kind, color, essl3External = true)
        }
      }
      for ((name, source) in sources) {
        val file = File(directory, name).apply { writeText(source) }
        val process = ProcessBuilder(validator!!, file.absolutePath).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        assertTrue("$name did not finish", process.waitFor(60, TimeUnit.SECONDS))
        assertEquals("$name:\n$output\n$source", 0, process.exitValue())
      }
    } finally {
      directory.deleteRecursively()
    }
  }

  private fun createTempDirectory(): File =
    File(System.getProperty("java.io.tmpdir"), "raw_stitch_shaders_${System.nanoTime()}").apply { mkdirs() }

  /** The validator named by GLSLANG_VALIDATOR, else the one on the PATH, else null. */
  private fun glslangValidator(): String? {
    System.getenv("GLSLANG_VALIDATOR")?.takeIf { File(it).canExecute() }?.let { return it }
    val path = System.getenv("PATH").orEmpty().split(File.pathSeparatorChar)
    return path.map { File(it, "glslangValidator") }.firstOrNull { it.canExecute() }?.absolutePath
  }
}
