package app.alextran.immich.core.raw

import kotlin.math.cos
import kotlin.math.sin

/**
 * The rawProjection JSON examples of section 3.5 of docs 18-design-projections-and-parsers.md, as Flutter sends them
 * (the Dart and Swift tests parse the same strings), and the build 17 JSON of the X3 (version 1).
 */
object RawFixtures {
  private const val X3_LENS_0 =
    """{"texture":%TEX0%,"region":%REGION0%,"cx":2967.48,"cy":2999.85,"fx":4627.54,"fy":4627.46,"xi":1.94817,
   "k1":0.38808271,"k2":1.29547262,"k3":-3.96876335,"k4":0.0,"k5":0.0,"p1":0.0017832,"p2":-0.00158561,
   "yaw":-0.029,"pitch":-0.038,"roll":89.51,
   "viewToLens":[-0.997338,0.072447,-0.008257,0.072914,0.989925,-0.121374,-0.00062,-0.121653,-0.992573]}"""

  private const val X3_LENS_1 =
    """{"texture":%TEX1%,"region":%REGION1%,"cx":8933.2,"cy":2998.62,"fx":4615.53,"fy":4615.53,"xi":1.94817,
   "k1":0.39306432,"k2":1.25673521,"k3":-3.90715361,"k4":0.0,"k5":0.0,"p1":-0.00147705,"p2":0.00090004,
   "yaw":-0.03,"pitch":-0.086,"roll":89.487,
   "viewToLens":[0.995908,-0.089867,0.009548,0.090361,0.988507,-0.121201,0.001453,0.121568,0.992582]}"""

  /** A. Insta360 X3, 4K single file, side by side. */
  val A =
    """{"version":2,"kind":"dualFisheye","layout":"sideBySide","camera":"Insta360 X3","frameWidth":3840,"frameHeight":1920,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":1920,"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8}],
 "secondUrl":null,"secondFallbackUrl":null,"trackOrder":null,"trackOrderSource":"single",
 "calibrationSource":"file","gravitySource":"imu",
 "model":"mei","canvasSquare":5952.0,"downBody":[0.989208,-0.08083,-0.122207],"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,
 "lenses":[
  ${lens(X3_LENS_0, 0, "[0.0,0.0,0.5,1.0]")},
  ${lens(X3_LENS_1, 0, "[0.5,0.0,0.5,1.0]")}]}"""

  /** B. Insta360 X5, two tracks in one file, field 80 = 1 (track 0 holds lens 1). */
  const val B =
    """{"version":2,"kind":"dualFisheye","layout":"twoTracks","camera":"Insta360 X5","frameWidth":7680,"frameHeight":3840,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":3840,"codec":"hvc1","codecs":"hvc1.1.6.L183","bitDepth":8},
           {"file":0,"videoTrack":1,"trackId":2,"width":3840,"height":3840,"codec":"hvc1","codecs":"hvc1.1.6.L183","bitDepth":8}],
 "secondUrl":null,"secondFallbackUrl":null,"trackOrder":[1,0],"trackOrderSource":"field80",
 "calibrationSource":"file","gravitySource":"imu",
 "model":"mei","canvasSquare":5376.0,"downBody":[1.0,0.0,0.0],"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,
 "lenses":[
  {"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":2688.0,"cy":2688.0,"fx":4180.0,"fy":4180.0,"xi":1.95,
   "k1":0.39,"k2":1.28,"k3":-3.94,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,"yaw":0.0,"pitch":0.0,"roll":90.0,
   "viewToLens":[-1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,-1.0]},
  {"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":8064.0,"cy":2688.0,"fx":4180.0,"fy":4180.0,"xi":1.95,
   "k1":0.39,"k2":1.28,"k3":-3.94,"k4":0.0,"k5":0.0,"p1":0.0,"p2":0.0,"yaw":0.0,"pitch":0.0,"roll":90.0,
   "viewToLens":[1.0,0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0]}]}"""

  const val C_URL = "http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/VID_20240908_193126_10_004.insv"
  const val C_SECOND_URL = "http://127.0.0.1:40213/tok/share-1/DCIM/Camera01/VID_20240908_193126_00_004.insv"

  /** C. Insta360 X3, 5.7K split pair, opened from the _10_ file (lens 0 in the second file), lens values of A. */
  val C =
    """{"version":2,"kind":"dualFisheye","layout":"twoFiles","camera":"Insta360 X3","frameWidth":5760,"frameHeight":2880,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":2880,"height":2880,"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8},
           {"file":1,"videoTrack":0,"trackId":1,"width":2880,"height":2880,"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8}],
 "secondUrl":"$C_SECOND_URL","secondFallbackUrl":null,
 "trackOrder":[1,0],"trackOrderSource":"fileName",
 "calibrationSource":"file","gravitySource":"imu",
 "model":"mei","canvasSquare":5952.0,"downBody":[0.989208,-0.08083,-0.122207],"maxTheta":100.0,"blendStart":85.0,"blendEnd":95.0,
 "lenses":[
  ${lens(X3_LENS_0, 1, "[0.0,0.0,1.0,1.0]")},
  ${lens(X3_LENS_1, 0, "[0.0,0.0,1.0,1.0]")}]}"""

  /** D. DJI Osmo 360, 8K .OSV (values of the real sample). */
  const val D =
    """{"version":2,"kind":"dualFisheye","layout":"twoTracks","camera":"Osmo 360","frameWidth":7680,"frameHeight":3840,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":3840,"height":3840,"codec":"hvc1","codecs":"hvc1.2.4.H156","bitDepth":10},
           {"file":0,"videoTrack":1,"trackId":2,"width":3840,"height":3840,"codec":"hvc1","codecs":"hvc1.2.4.H156","bitDepth":10}],
 "secondUrl":null,"secondFallbackUrl":null,"trackOrder":[0,1],"trackOrderSource":"dji",
 "calibrationSource":"file","gravitySource":"none",
 "model":"kannalaBrandt","canvasSquare":3840.0,"downBody":[1.0,0.0,0.0],"maxTheta":94.0,"blendStart":87.0,"blendEnd":93.0,
 "lenses":[
  {"texture":0,"region":[0.0,0.0,1.0,1.0],"cx":1920.85339355,"cy":1916.73022461,"fx":1046.37927246,"fy":1046.16796875,
   "k1":0.068134,"k2":-0.013797,"k3":0.0117944,"k4":-0.00733225,"k5":0.00104408,"p1":0.0,"p2":0.0,
   "yaw":179.5457,"pitch":90.616882,"roll":-1.3556259,
   "viewToLens":[-0.999691,-0.023657,0.007672,-0.023572,0.999662,0.010951,-0.007928,0.010766,-0.999911]},
  {"texture":1,"region":[0.0,0.0,1.0,1.0],"cx":5750.76611328,"cy":1916.24243164,"fx":1048.02502441,"fy":1047.87451172,
   "k1":0.0644356,"k2":-0.00886799,"k3":0.00849704,"k4":-0.00639127,"k5":0.00095551,"p1":0.0,"p2":0.0,
   "yaw":-0.52270812,"pitch":90.597488,"roll":0.40385118,
   "viewToLens":[0.999933,-0.007031,-0.009205,0.007135,0.999911,0.011292,0.009124,-0.011357,0.999894]}]}"""

  private const val GOPRO_FACES =
    """"faces":[
  {"texture":0,"slot":0,"forward":[-1,0,0],"right":[0,0,1],"down":[0,-1,0]},
  {"texture":0,"slot":1,"forward":[0,0,1],"right":[1,0,0],"down":[0,-1,0]},
  {"texture":0,"slot":2,"forward":[1,0,0],"right":[0,0,-1],"down":[0,-1,0]},
  {"texture":1,"slot":0,"forward":[0,-1,0],"right":[0,0,-1],"down":[-1,0,0]},
  {"texture":1,"slot":1,"forward":[0,0,-1],"right":[0,1,0],"down":[-1,0,0]},
  {"texture":1,"slot":2,"forward":[0,1,0],"right":[0,0,1],"down":[-1,0,0]}]"""

  /** E. GoPro MAX 2, 10 bit .360, tracks of 5952 x 1920. */
  const val E =
    """{"version":2,"kind":"eacGoPro","layout":"twoTracks","camera":"GoPro MAX 2","frameWidth":7680,"frameHeight":3840,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":5952,"height":1920,"codec":"hvc1","codecs":"hvc1.2.4.L153","bitDepth":10},
           {"file":0,"videoTrack":1,"trackId":6,"width":5952,"height":1920,"codec":"hvc1","codecs":"hvc1.2.4.L153","bitDepth":10}],
 "secondUrl":null,"secondFallbackUrl":null,"trackOrder":null,"trackOrderSource":"goPro",
 "calibrationSource":"trackGeometry","gravitySource":"none",
 "face":1920,"overlap":96,"half":1008,"middle":2016,"right":3936,
 "viewToCamera":[1.0,0.0,0.0,0.0,-1.0,0.0,0.0,0.0,1.0],
 $GOPRO_FACES}"""

  /** The GoPro MAX of the real sample GS010013.360: tracks of 4096 x 1344, its quarter turn. */
  const val MAX =
    """{"version":2,"kind":"eacGoPro","layout":"twoTracks","camera":"GoPro MAX","frameWidth":5376,"frameHeight":2688,
 "tracks":[{"file":0,"videoTrack":0,"trackId":1,"width":4096,"height":1344,"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8},
           {"file":0,"videoTrack":1,"trackId":6,"width":4096,"height":1344,"codec":"hvc1","codecs":"hvc1.1.6.L153","bitDepth":8}],
 "secondUrl":null,"secondFallbackUrl":null,"trackOrder":null,"trackOrderSource":"goPro",
 "calibrationSource":"trackGeometry","gravitySource":"none",
 "face":1344,"overlap":32,"half":688,"middle":1376,"right":2720,
 "viewToCamera":[0.0,1.0,0.0,1.0,0.0,0.0,0.0,0.0,1.0],
 $GOPRO_FACES}"""

  /** The MAX 2 8 bit geometry (5888 x 1920) with the MAX 2 matrix: the test vectors of section 9.2. */
  val MAX2_8BIT =
    E.replace("5952", "5888")
      .replace("\"overlap\":96,\"half\":1008,\"middle\":2016,\"right\":3936", "\"overlap\":64,\"half\":992,\"middle\":1984,\"right\":3904")

  /** The build 17 JSON of the X3 (version 1, no "version"), as DualFisheyeCalibrationTest has it. */
  const val X3_V1 =
    """{"kind":"dualFisheye","model":"mei","frameWidth":5760,"frameHeight":2880,"canvasSquare":5952,
      "downBody":[0.9885,-0.0753,-0.1310],
      "lenses":[{"xi":1.948,"fx":4627.5,"fy":4627.5,"cx":2967.5,"cy":2999.9,"yaw":-0.029,"pitch":-0.038,"roll":89.51,
      "k1":0.388,"k2":1.295,"k3":-3.969,"p1":0.0018,"p2":-0.0016},
      {"xi":1.948,"fx":4615.5,"fy":4615.5,"cx":8933.2,"cy":2998.6,"yaw":0.0,"pitch":0.0,"roll":89.49,
      "k1":0.388,"k2":1.295,"k3":-3.969,"p1":0.0,"p2":0.0}]}"""

  private fun lens(template: String, texture: Int, region: String): String =
    template.replace("%TEX0%", texture.toString()).replace("%TEX1%", texture.toString())
      .replace("%REGION0%", region).replace("%REGION1%", region)

  /** View direction of longitude [lonDegrees] and latitude [latDegrees]. */
  fun view(lonDegrees: Double, latDegrees: Double): DoubleArray {
    val lon = Math.toRadians(lonDegrees)
    val lat = Math.toRadians(latDegrees)
    return doubleArrayOf(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
  }
}
