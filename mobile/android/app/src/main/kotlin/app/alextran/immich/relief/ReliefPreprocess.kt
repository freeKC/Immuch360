package app.alextran.immich.relief

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

// The input of the depth model of the Meta Quest made from a photo, and its output cut back to the photo (design-final
// 2026-10-26, sections 2.3 point 5 and 3.4 point 4). The same rule as the computers (lib/desktop/ai/relief), so that
// both draw the same map from the same photo. Plain JVM code, without Android: the photo comes as ARGB rows, as
// Bitmap.getPixels gives them, and the tensor goes to the engine as a float array.

/**
 * Where the photo lies in the input of the model, in pixels of the input: the whole input when it is stretched, a
 * centred rectangle when it keeps its proportions
 */
data class ReliefFrame(val x: Int, val y: Int, val width: Int, val height: Int) {
  val stretched: Boolean
    get() =
      x == 0 && y == 0 && width == ReliefPreprocess.INPUT_WIDTH && height == ReliefPreprocess.INPUT_HEIGHT
}

/** The input of the model: [tensor] in NCHW float32, and the [frame] of the photo in it */
class ReliefInput(val tensor: FloatArray, val frame: ReliefFrame)

/**
 * The input of Depth Anything V2 Small, fixed by its LiteRT export at `[1, 3, 518, 686]`:
 * 1. **Frame.** A photo 1.0 to 1.9 times as wide as high is stretched to the whole 686 x 518 (the model card says the
 *    export is validated stretched). Another one (a portrait, a flat panorama) keeps its proportions: the side that
 *    limits takes the whole input, the other one `round(side * 686 / W)` or `round(side * 518 / H)` (half up, at least
 *    1), centred with the offset rounded down, on a background of the mean colour of the photo.
 * 2. **Area average.** Each pixel of the frame is the mean of the photo over the area it covers, the pixels at its
 *    edges weighted by the part they share with it; the same rule enlarges a photo smaller than the frame. In double
 *    precision, never rounded to bytes.
 * 3. **Normalisation.** `(v / 255 - mean) / std` with the ImageNet means 0.485, 0.456, 0.406 and deviations 0.229,
 *    0.224, 0.225, in NCHW: the red plane, the green plane, the blue plane, each row after row. 4.3 MB.
 *
 * The output of the model, `[1, 518, 686]`, is cut back to the frame by [cropDepth] before relief-v1 normalises it.
 */
object ReliefPreprocess {
  const val INPUT_WIDTH = 686
  const val INPUT_HEIGHT = 518
  const val TENSOR_SIZE = 3 * INPUT_WIDTH * INPUT_HEIGHT

  /** A photo whose width over height is in this range is stretched */
  const val MIN_STRETCH_RATIO = 1.0
  const val MAX_STRETCH_RATIO = 1.9

  private val MEAN = doubleArrayOf(0.485, 0.456, 0.406)
  private val STD = doubleArrayOf(0.229, 0.224, 0.225)

  /** The frame of a photo of [width] x [height] in the input */
  fun frameFor(width: Int, height: Int): ReliefFrame {
    require(width > 0 && height > 0) { "a photo of $width x $height" }
    val ratio = width.toDouble() / height
    if (ratio >= MIN_STRETCH_RATIO && ratio <= MAX_STRETCH_RATIO) {
      return ReliefFrame(0, 0, INPUT_WIDTH, INPUT_HEIGHT)
    }
    // width / height <= 686 / 518: the height limits
    return if (width.toLong() * INPUT_HEIGHT <= height.toLong() * INPUT_WIDTH) {
      val fitted = max(1, min(INPUT_WIDTH, roundedRatio(width.toLong() * INPUT_HEIGHT, height.toLong())))
      ReliefFrame((INPUT_WIDTH - fitted) / 2, 0, fitted, INPUT_HEIGHT)
    } else {
      val fitted = max(1, min(INPUT_HEIGHT, roundedRatio(height.toLong() * INPUT_WIDTH, width.toLong())))
      ReliefFrame(0, (INPUT_HEIGHT - fitted) / 2, INPUT_WIDTH, fitted)
    }
  }

  /** [prepare] for a photo held in one array of ARGB pixels, row after row */
  fun prepare(pixels: IntArray, width: Int, height: Int, out: FloatArray = FloatArray(TENSOR_SIZE)): ReliefInput {
    require(width > 0 && height > 0 && pixels.size >= width.toLong() * height) { "a photo of $width x $height" }
    return prepare(width, height, { y, row -> pixels.copyInto(row, 0, y * width, (y + 1) * width) }, out)
  }

  /**
   * The input of the model for a photo of [width] x [height] whose rows [read] gives, in [out]. Each row is read once,
   * in order: the photo is never copied whole.
   */
  fun prepare(width: Int, height: Int, read: PixelRowReader, out: FloatArray = FloatArray(TENSOR_SIZE)): ReliefInput {
    require(width > 0 && height > 0) { "a photo of $width x $height" }
    require(out.size == TENSOR_SIZE) { "a tensor of $TENSOR_SIZE values, not ${out.size}" }
    val frame = frameFor(width, height)
    val across = AreaWeights(width, frame.width)
    val down = AreaWeights(height, frame.height)
    val pixels = IntArray(width)
    // The last source row read and averaged across, R, G, B for each column of the frame
    val sourceRow = DoubleArray(3 * frame.width)
    var lastRead = -1
    // The frame, R, G, B for each pixel, row after row
    val area = DoubleArray(3 * frame.width * frame.height)
    val rowSum = DoubleArray(3 * frame.width)
    for (fy in 0 until frame.height) {
      rowSum.fill(0.0)
      var weightSum = 0.0
      for (k in 0 until down.count[fy]) {
        val sy = down.first[fy] + k
        val weight = down.weight(fy, k)
        if (sy != lastRead) {
          read.read(sy, pixels)
          averageAcross(pixels, across, sourceRow)
          lastRead = sy
        }
        for (i in rowSum.indices) rowSum[i] += sourceRow[i] * weight
        weightSum += weight
      }
      val base = 3 * frame.width * fy
      for (i in rowSum.indices) area[base + i] = rowSum[i] / weightSum
    }
    val background = DoubleArray(3)
    if (!frame.stretched) {
      for (i in area.indices) background[i % 3] += area[i]
      for (c in 0..2) background[c] /= (frame.width * frame.height).toDouble()
    }
    val plane = INPUT_WIDTH * INPUT_HEIGHT
    for (c in 0..2) {
      val outside = normalize(background[c], c)
      for (y in 0 until INPUT_HEIGHT) {
        val fy = y - frame.y
        for (x in 0 until INPUT_WIDTH) {
          val fx = x - frame.x
          out[c * plane + y * INPUT_WIDTH + x] =
            if (fy in 0 until frame.height && fx in 0 until frame.width) {
              normalize(area[3 * (fy * frame.width + fx) + c], c)
            } else {
              outside
            }
        }
      }
    }
    return ReliefInput(out, frame)
  }

  /**
   * The depth map of the photo: the part of [output] (`[1, 518, 686]`, row after row) its [frame] covers, a new array
   * of `frame.width x frame.height` values, row after row
   */
  fun cropDepth(output: FloatArray, frame: ReliefFrame): FloatArray {
    require(output.size == INPUT_WIDTH * INPUT_HEIGHT) { "an output of $INPUT_WIDTH x $INPUT_HEIGHT" }
    require(
      frame.x >= 0 &&
        frame.y >= 0 &&
        frame.width > 0 &&
        frame.height > 0 &&
        frame.x + frame.width <= INPUT_WIDTH &&
        frame.y + frame.height <= INPUT_HEIGHT
    ) {
      "$frame is not in the input"
    }
    val map = FloatArray(frame.width * frame.height)
    for (y in 0 until frame.height) {
      val from = (frame.y + y) * INPUT_WIDTH + frame.x
      output.copyInto(map, y * frame.width, from, from + frame.width)
    }
    return map
  }

  private fun normalize(value: Double, channel: Int): Float = ((value / 255.0 - MEAN[channel]) / STD[channel]).toFloat()

  /** `round(a / b)` for positive values, half up, in integers */
  private fun roundedRatio(a: Long, b: Long): Int = ((2 * a + b) / (2 * b)).toInt()

  /** One row of the photo averaged over the columns of the frame, R, G, B for each column */
  private fun averageAcross(pixels: IntArray, across: AreaWeights, out: DoubleArray) {
    for (fx in 0 until across.size) {
      var r = 0.0
      var g = 0.0
      var b = 0.0
      var weightSum = 0.0
      for (k in 0 until across.count[fx]) {
        val p = pixels[across.first[fx] + k]
        val weight = across.weight(fx, k)
        r += ((p shr 16) and 0xFF) * weight
        g += ((p shr 8) and 0xFF) * weight
        b += (p and 0xFF) * weight
        weightSum += weight
      }
      out[3 * fx] = r / weightSum
      out[3 * fx + 1] = g / weightSum
      out[3 * fx + 2] = b / weightSum
    }
  }

  /**
   * How the [source] pixels of a line spread over the [size] pixels of the frame: the pixel i of the frame covers
   * `[i * source / size, (i + 1) * source / size)` of the source, and takes each source pixel it touches with the
   * length they share
   */
  private class AreaWeights(source: Int, val size: Int) {
    val first = IntArray(size)
    val count = IntArray(size)
    private val start = DoubleArray(size)
    private val end = DoubleArray(size)

    init {
      for (i in 0 until size) {
        start[i] = i.toDouble() * source / size
        end[i] = (i + 1).toDouble() * source / size
        first[i] = floor(start[i]).toInt()
        val last = min(source, ceil(end[i]).toInt())
        count[i] = max(1, last - first[i])
      }
    }

    /** The weight of the k-th source pixel of the pixel [i] of the frame */
    fun weight(i: Int, k: Int): Double {
      val j = (first[i] + k).toDouble()
      return min(j + 1, end[i]) - max(j, start[i])
    }
  }
}
