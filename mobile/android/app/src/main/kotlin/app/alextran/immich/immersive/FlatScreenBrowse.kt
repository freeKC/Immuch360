package app.alextran.immich.immersive

/**
 * What the quad shows of a photo with two eyes: both eyes (3D), the relief of the headset on its 2.5D mesh (see
 * [ReliefMesh], experimental), or the left eye for both (2D)
 */
internal enum class StereoView {
  THREE_D,
  MESH_25D,
  TWO_D,
}

/**
 * The view kept while browsing the photos of a flat screen (issue 19, point 5): the view of the photo before applies
 * to the next one reached by previous, next or the slideshow, when that photo offers it. 2D and 3D go to every photo
 * of two eyes, 2.5D to a relief made in the headset only (any other photo of two eyes then shows in 3D); one picture
 * shows as it is. A photo opened from the app starts from its request, as before. Pure, unit tested.
 */
internal object BrowseView {
  /**
   * The view a photo starts in: [requested] (3D, or 2.5D for a relief whose request asks it) without a [kept] view, a
   * photo opened from the app; else the kept one where the photo offers it ([holdsTwoEyes], [relief]).
   */
  fun startView(kept: StereoView?, requested: StereoView, holdsTwoEyes: Boolean, relief: Boolean): StereoView =
    when {
      kept == null || !holdsTwoEyes -> requested
      kept == StereoView.MESH_25D -> if (relief) StereoView.MESH_25D else StereoView.THREE_D
      else -> kept
    }

  /**
   * Whether the relief of a photo that starts in [view] is made at once: not in 2D, where the user browses the
   * originals, so that no heat and no battery go to a relief nobody looks at; the 3D button makes it then.
   */
  fun computesRelief(view: StereoView): Boolean = view != StereoView.TWO_D
}

/**
 * The relief strengths of the AI relief made in the headset (release 46, lot feat-relief-strength-46): the whole
 * parallax of relief-v1, under the names the app keeps in its settings (ReliefStrength in Dart), checked against the
 * contract fixture stereo_pair_contract_v1.json so that the two sides cannot drift. The button "Relief: Normal" of the
 * viewer goes through them in this order (issue 19, point 4). Pure, unit tested.
 */
internal enum class ReliefStrengthChoice(val wire: String, val parallax: Double) {
  SUBTLE("subtle", 0.015),
  NORMAL("normal", 0.02),
  STRONG("strong", 0.03);

  /** The strength the button goes to next: Subtle, Normal, Strong, then Subtle again. */
  val next: ReliefStrengthChoice
    get() = entries[(ordinal + 1) % entries.size]

  /** The key of its name among the labels of the viewer. */
  val labelKey: String
    get() = "aiReliefStrength_$wire"

  companion object {
    /** The label of the button, "Relief: {strength}", and where its name goes. */
    const val LABEL_INFO = "aiReliefStrengthInfo"
    const val STRENGTH = "{strength}"

    /** The strength of [parallax], null for a parallax of none of them (a later version of the app). */
    fun ofParallax(parallax: Double): ReliefStrengthChoice? =
      entries.firstOrNull { kotlin.math.abs(it.parallax - parallax) < 1e-9 }
  }
}
