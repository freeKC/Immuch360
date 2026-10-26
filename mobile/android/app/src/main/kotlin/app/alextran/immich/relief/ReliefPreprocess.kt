package app.alextran.immich.relief

import kotlin.math.max
import kotlin.math.min

// The input of the depth model of the Meta Quest made from a photo, and its output cut back to the photo (design-final
// 2026-10-26, sections 2.3 point 5 and 3.4 point 4). The same rule and the same arithmetic as the computers
// (lib/desktop/ai/relief/relief_input.dart), so that from the same pixels both give the same float32 values and draw
// the same map. Plain JVM code, without Android: the photo comes as ARGB rows, as Bitmap.getPixels gives them, and the
// tensor goes to the engine as a float array.

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
 * 1. **Frame.** A photo 1.0 to 1.9 times as wide as high (`width >= height` and `10 * width <= 19 * height`, in
 *    integers) is stretched to the whole 686 x 518: the model card says the export is validated stretched. Another one
 *    (a portrait, a flat panorama) keeps its proportions: the side that limits takes the whole input, the other one
 *    `round(side * 686 / W)` or `round(side * 518 / H)` (half up, in integers, at least 1), centred with the offset
 *    rounded down, on a background of the mean colour of the photo.
 * 2. **Area average, exact in integers.** On each axis of S photo pixels and N frame pixels, the frame pixel i covers
 *    `[i * S, (i + 1) * S)` and the photo pixel j covers `[j * N, (j + 1) * N)`, in units of 1 / N of a photo pixel.
 *    The sum of `overlapX * overlapY * value` over the photo, divided by `S_x * S_y` as a double, is the value of the
 *    frame pixel. It reduces and enlarges alike.
 * 3. **Background.** The sum of the photo divided by its number of pixels, as a double.
 * 4. **Normalisation.** `(v / 255 - mean) / std` in double with the ImageNet means 0.485, 0.456, 0.406 and deviations
 *    0.229, 0.224, 0.225, stored in float32, NCHW: the red plane, the green plane, the blue plane, each row after row.
 *    4.3 MB. The alpha of the photo is not read.
 *
 * The output of the model, `[1, 518, 686]`, is cut back to the frame by [cropDepth] before relief-v1 normalises it.
 */
object ReliefPreprocess {
  const val INPUT_WIDTH = 686
  const val INPUT_HEIGHT = 518
  const val TENSOR_SIZE = 3 * INPUT_WIDTH * INPUT_HEIGHT

  private val MEAN = doubleArrayOf(0.485, 0.456, 0.406)
  private val STD = doubleArrayOf(0.229, 0.224, 0.225)

  /** The frame of a photo of [width] x [height] in the input */
  fun frameFor(width: Int, height: Int): ReliefFrame {
    require(width > 0 && height > 0) { "a photo of $width x $height" }
    if (width >= height && 10L * width <= 19L * height) {
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
    val columns = AxisCover(width, frame.width)
    val rows = AxisCover(height, frame.height)
    val pixels = IntArray(width)
    // The sums of overlapX * value of the last photo row read, R, G, B for each column of the frame: the next row of
    // the frame may share that photo row
    val across = LongArray(3 * frame.width)
    var acrossRow = -1
    // The sum of the photo, in units of 1 / frame.width: each photo pixel is covered by frame.width units in all
    val photoSum = LongArray(3)
    val sums = LongArray(3 * frame.width)
    val plane = INPUT_WIDTH * INPUT_HEIGHT
    val area = (width.toLong() * height).toDouble()
    for (outY in 0 until frame.height) {
      sums.fill(0L)
      for (k in rows.first[outY] until rows.first[outY + 1]) {
        val photoY = rows.source[k]
        val overlapY = rows.overlap[k].toLong()
        if (photoY != acrossRow) {
          acrossRow = photoY
          read.read(photoY, pixels)
          sumAcross(pixels, columns, across)
          for (i in across.indices) photoSum[i % 3] += across[i]
        }
        for (i in sums.indices) sums[i] += overlapY * across[i]
      }
      val at = (frame.y + outY) * INPUT_WIDTH + frame.x
      for (outX in 0 until frame.width) {
        for (c in 0..2) out[c * plane + at + outX] = normalize(sums[3 * outX + c] / area, c)
      }
    }
    if (!frame.stretched) {
      for (c in 0..2) {
        val value = normalize(photoSum[c] / (frame.width * area), c)
        val start = c * plane
        for (y in 0 until INPUT_HEIGHT) {
          val row = start + y * INPUT_WIDTH
          if (y < frame.y || y >= frame.y + frame.height) {
            out.fill(value, row, row + INPUT_WIDTH)
          } else {
            out.fill(value, row, row + frame.x)
            out.fill(value, row + frame.x + frame.width, row + INPUT_WIDTH)
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

  /** The sums of `overlapX * value` of one photo row, R, G, B for each column of the frame */
  private fun sumAcross(pixels: IntArray, columns: AxisCover, out: LongArray) {
    for (outX in 0 until columns.size) {
      var r = 0L
      var g = 0L
      var b = 0L
      for (k in columns.first[outX] until columns.first[outX + 1]) {
        val weight = columns.overlap[k].toLong()
        val p = pixels[columns.source[k]]
        r += weight * ((p shr 16) and 0xFF)
        g += weight * ((p shr 8) and 0xFF)
        b += weight * (p and 0xFF)
      }
      out[3 * outX] = r
      out[3 * outX + 1] = g
      out[3 * outX + 2] = b
    }
  }

  /**
   * For each of the [size] frame pixels along one axis of [photoSize] photo pixels, the photo pixels it covers and by
   * how much, in units of 1 / [size] of a photo pixel: the frame pixel i covers `[i * photoSize, (i + 1) * photoSize)`,
   * the photo pixel j `[j * size, (j + 1) * size)`. The covers of i are `first[i]` to `first[i + 1] - 1` in [source]
   * and [overlap].
   */
  private class AxisCover(photoSize: Int, val size: Int) {
    val first = IntArray(size + 1)
    val source: IntArray
    val overlap: IntArray

    init {
      val sources = ArrayList<Int>()
      val overlaps = ArrayList<Int>()
      for (i in 0 until size) {
        first[i] = sources.size
        val start = i.toLong() * photoSize
        val end = (i + 1).toLong() * photoSize
        var j = (start / size).toInt()
        while (j.toLong() * size < end && j < photoSize) {
          val from = maxOf(j.toLong() * size, start)
          val to = minOf((j + 1).toLong() * size, end)
          if (to > from) {
            sources += j
            overlaps += (to - from).toInt()
          }
          j++
        }
      }
      first[size] = sources.size
      source = sources.toIntArray()
      overlap = overlaps.toIntArray()
    }
  }
}
