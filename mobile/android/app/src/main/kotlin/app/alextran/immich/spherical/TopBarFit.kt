package app.alextran.immich.spherical

/**
 * The top bar of the 360° video player in portrait (issue 20: the player no longer forces landscape). Its close button
 * and up to five buttons of 48 dp (audio track, stabilisation, coverage, 3D, gyroscope) took 352 dp with their 8 dp
 * margins, the title squeezed to nothing on a phone of 360 dp: below [compactBelowDp], the buttons sit side by side
 * without margins (their 48 dp keep the touch targets), which leaves the title about 40 dp. Unit tested.
 */
internal object TopBarFit {
  /** The usual margin before each button, in dp, as the layout sets it */
  const val MARGIN_DP = 8

  /** The margin before each button of the top bar on a window [widthDp] wide; 0 below [compactBelowDp] */
  fun buttonMarginDp(widthDp: Int, compactBelowDp: Int): Int = if (widthDp in 1 until compactBelowDp) 0 else MARGIN_DP
}
