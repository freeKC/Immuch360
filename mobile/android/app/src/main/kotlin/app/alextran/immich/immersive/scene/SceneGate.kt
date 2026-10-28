package app.alextran.immich.immersive.scene

import app.alextran.immich.immersive.VolumetricSceneSpec

/**
 * The gate of the 3D scenes in the headset (design-final 2026-10-27, section 3.5, spec 8.3). The Dart side reads it
 * first from the packet at the head of the file, so the button is greyed with its reason before anything downloads;
 * the viewer checks again here, on the request and the size of the cached file before it reads the tail, then on the
 * glb as read, whose textures it decodes at the sample sizes this gate gives.
 *
 * 1. Quest 3 (eureka), Quest 3S (panther), and any headset this build does not know (the AI relief takes them so):
 *    200 000 vertices and 400 000 triangles at most, 4 textures at most of 4096 px a side at most, a file of 64 MiB.
 * 2. Quest 2 (hollywood), Quest Pro (seacliff): 100 000 vertices and 200 000 triangles at most, the same textures
 *    decoded at half beyond 2048 px, a file of 64 MiB.
 * 3. Every headset: the free memory (ActivityManager.MemoryInfo.availMem) holds three times the decoded textures;
 *    THERMAL_STATUS_SEVERE or worse refused.
 *
 * The caps are a hypothesis until the second session of MQ in the headset (section 3.6), which may change them; the
 * format does not change with them. Pure JVM, tested by SceneGateTest.
 */
internal object SceneGate {
  /** PowerManager.THERMAL_STATUS_SEVERE: from this status on no scene opens */
  const val THERMAL_STATUS_SEVERE = 3

  /** The free memory must hold this many times the decoded textures */
  const val MEMORY_FACTOR = 3

  /** Bytes per decoded pixel (ARGB_8888) */
  const val BYTES_PER_PIXEL = 4

  /** The largest file the headset reads a scene from */
  const val MAX_FILE_BYTES = 64L * 1024 * 1024

  /** The version of our packets this build reads (Immuch360:FormatVersion) */
  const val FORMAT_VERSION = SceneFile.SUPPORTED_FORMAT_VERSION

  /** Quest 3, Quest 3S, and a headset this build does not know */
  val CURRENT_HEADSETS = SceneCaps(200_000, 400_000, 4, 4096, null, MAX_FILE_BYTES)

  /** Quest 2 and Quest Pro: half the geometry, the textures decoded at half beyond 2048 px */
  val OLDER_HEADSETS = SceneCaps(100_000, 200_000, 4, 4096, 2048, MAX_FILE_BYTES)

  /** Build.DEVICE of the Quest 2 and the Quest Pro (reliefOlderHeadsets of relief_gate.provider.dart) */
  val OLDER_DEVICES = setOf("hollywood", "seacliff")

  /** The caps of the headset whose Build.DEVICE is [device] */
  fun capsFor(device: String?): SceneCaps = if (device in OLDER_DEVICES) OLDER_HEADSETS else CURRENT_HEADSETS

  /** The sample size a texture of [size] is decoded at on a headset of [caps]: 1, or 2 beyond the halving side */
  fun sampleSize(size: TextureSize, caps: SceneCaps): Int {
    val half = caps.halveTexturesAbove ?: return 1
    return if (maxOf(size.width, size.height) > half) 2 else 1
  }

  /** The bytes of a texture of [size] decoded at [sample]: each side divided and rounded up, as the decoder does */
  fun decodedBytes(size: TextureSize, sample: Int): Long =
    BYTES_PER_PIXEL.toLong() * ((size.width + sample - 1) / sample) * ((size.height + sample - 1) / sample)

  /**
   * What the packet at the head of a file says before anything is weighed, the request it makes ([SceneHead.spec])
   * being null for a packet this build cannot read:
   * 1. a later Immuch360:FormatVersion, whatever its kind, or a later SceneFormat glb-layers-vN:
   *    [SceneRefusal.NEWER_VERSION], "Made by a newer version of Immuch360";
   * 2. another Kind of ours, or a SceneFormat written that is not a format of ours: [SceneRefusal.NOT_OURS];
   * 3. null otherwise: the request is then weighed by [check]. A packet of our kind and version with a field missing
   *    or a value that cannot be right, SceneFormat absent or empty included, passes here with no request: the viewer
   *    says the scene data is missing (SceneFileProblem.MISSING, "The 3D scene data is missing from this file"), as
   *    for a tail gone.
   */
  fun checkHead(head: SceneHead): SceneRefusal? {
    if ((head.formatVersion ?: FORMAT_VERSION) > FORMAT_VERSION) return SceneRefusal.NEWER_VERSION
    val format = head.sceneFormat
    if (!format.isNullOrEmpty() && format != GlbReader.FORMAT) {
      val version = GlbReader.formatVersionOf(format)
      if (version != null && version > 1) return SceneRefusal.NEWER_VERSION
    }
    if (head.kind != SceneFile.KIND) return SceneRefusal.NOT_OURS
    return if (format.isNullOrEmpty() || format == GlbReader.FORMAT) null else SceneRefusal.NOT_OURS
  }

  /**
   * Whether a scene of [weight] opens on a headset of [caps] with [availableMemory] bytes free (null when unknown)
   * at the thermal status [thermalStatus] (null when unknown). In this order: the version, the geometry (triangles,
   * then vertices), the textures (count, then side), the file, the memory, the heat. The memory is weighed only once
   * the textures are known (the glb read).
   */
  fun check(weight: SceneWeight, caps: SceneCaps, availableMemory: Long?, thermalStatus: Int?): SceneVerdict {
    if ((weight.formatVersion ?: FORMAT_VERSION) > FORMAT_VERSION) {
      return SceneVerdict.Refused(SceneRefusal.NEWER_VERSION)
    }
    if (weight.sceneFormat != GlbReader.FORMAT) {
      val version = GlbReader.formatVersionOf(weight.sceneFormat)
      return SceneVerdict.Refused(
        if (version != null && version > 1) SceneRefusal.NEWER_VERSION else SceneRefusal.NOT_OURS
      )
    }
    fun heavy(limit: SceneLimit, value: Long, max: Long) =
      SceneVerdict.Refused(SceneRefusal.TOO_HEAVY, limit, value, max)
    if (weight.triangles > caps.maxTriangles) {
      return heavy(SceneLimit.TRIANGLES, weight.triangles.toLong(), caps.maxTriangles.toLong())
    }
    if (weight.vertices > caps.maxVertices) {
      return heavy(SceneLimit.VERTICES, weight.vertices.toLong(), caps.maxVertices.toLong())
    }
    val textures = weight.textures
    if (textures != null && textures.size > caps.maxTextures) {
      return heavy(SceneLimit.TEXTURES, textures.size.toLong(), caps.maxTextures.toLong())
    }
    if (weight.textureMax > caps.maxTextureSide) {
      return heavy(SceneLimit.TEXTURE_SIDE, weight.textureMax.toLong(), caps.maxTextureSide.toLong())
    }
    if (weight.fileBytes > caps.maxFileBytes) return heavy(SceneLimit.FILE, weight.fileBytes, caps.maxFileBytes)
    val samples = textures?.map { sampleSize(it, caps) }.orEmpty()
    val decoded = textures?.indices?.sumOf { decodedBytes(textures[it], samples[it]) } ?: 0L
    if (textures != null && availableMemory != null && availableMemory < MEMORY_FACTOR * decoded) {
      return SceneVerdict.Refused(SceneRefusal.NOT_ENOUGH_MEMORY, null, availableMemory, MEMORY_FACTOR * decoded)
    }
    if (thermalStatus != null && thermalStatus >= THERMAL_STATUS_SEVERE) {
      return SceneVerdict.Refused(SceneRefusal.TOO_WARM)
    }
    return SceneVerdict.Open(samples, decoded)
  }
}

/**
 * What a headset takes: at most [maxVertices] vertices and [maxTriangles] triangles in all, [maxTextures] textures of
 * at most [maxTextureSide] pixels a side, decoded at half beyond [halveTexturesAbove] pixels (null: never), a file of
 * at most [maxFileBytes] bytes
 */
internal data class SceneCaps(
  val maxVertices: Int,
  val maxTriangles: Int,
  val maxTextures: Int,
  val maxTextureSide: Int,
  val halveTexturesAbove: Int?,
  val maxFileBytes: Long,
)

/** The size of a texture in pixels, read from its JPEG */
internal data class TextureSize(val width: Int, val height: Int)

/**
 * What the gate weighs: Immuch360:FormatVersion of the packet, the scene format, the bytes of the file, the vertices
 * and triangles in all, the longest side of the largest texture, and each texture once the glb is read (null before)
 */
internal data class SceneWeight(
  val formatVersion: Int?,
  val sceneFormat: String?,
  val fileBytes: Long,
  val vertices: Int,
  val triangles: Int,
  val textureMax: Int,
  val textures: List<TextureSize>?,
) {
  companion object {
    /** The weight a request says, before the tail is read */
    fun of(spec: VolumetricSceneSpec, formatVersion: Int?, fileBytes: Long) =
      SceneWeight(formatVersion, spec.format, fileBytes, spec.vertices, spec.triangles, spec.textureMax, null)

    /** The weight of a scene as read */
    fun of(scene: GlbScene, formatVersion: Int?, fileBytes: Long): SceneWeight {
      val textures = scene.textures.map { TextureSize(it.width, it.height) }
      return SceneWeight(
        formatVersion = formatVersion,
        sceneFormat = scene.format,
        fileBytes = fileBytes,
        vertices = scene.vertices,
        triangles = scene.triangles,
        textureMax = textures.maxOfOrNull { maxOf(it.width, it.height) } ?: 0,
        textures = textures,
      )
    }
  }
}

/** Why a scene stays flat, the photo shown and the other versions within reach */
internal enum class SceneRefusal {
  /** "Made by a newer version of Immuch360" */
  NEWER_VERSION,

  /** "Not a scene made by Immuch360" */
  NOT_OURS,

  /** "This scene is too heavy for this headset (N triangles, at most M)" */
  TOO_HEAVY,

  /** "Not enough free memory" */
  NOT_ENOUGH_MEMORY,

  /** "Headset too warm" */
  TOO_WARM,
}

/** What a scene too heavy goes beyond */
internal enum class SceneLimit {
  TRIANGLES,
  VERTICES,
  TEXTURES,
  TEXTURE_SIDE,
  FILE,
}

/** What the gate says */
internal sealed interface SceneVerdict {
  /** The scene opens; each texture decoded at its [sampleSizes] (inSampleSize) makes [decodedBytes] in all */
  data class Open(val sampleSizes: List<Int>, val decodedBytes: Long) : SceneVerdict

  /** The scene stays flat for [reason]; a scene too heavy, or the memory, with the [value] found and its [limit] */
  data class Refused(
    val reason: SceneRefusal,
    val limit: SceneLimit? = null,
    val value: Long = 0,
    val max: Long = 0,
  ) : SceneVerdict
}
