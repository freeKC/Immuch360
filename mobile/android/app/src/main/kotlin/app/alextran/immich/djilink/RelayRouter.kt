package app.alextran.immich.djilink

/**
 * The relay half of the tee (p2/relay-bandwidth-2026-10-25.md, 7.2): every drone unit goes to the receivers on the full
 * stream through [RelayServer], then to the phone's steady stream ([RelayTranscoder.offer]: a shared reference in its
 * input queue, never a copy). A switch to the steady stream that the unit brings is asked only after the steady stream
 * saw it: a key unit with new parameter sets makes decoder 2 again first, and the encoder is made on the new one
 * (p2/review-bandwidth-2026-10-25.md M1). The pilot's decoder was fed before ([TeeSink] calls this inside its catch); a
 * failure of the steady stream here never stops the full stream, it is only counted.
 */
class RelayRouter(private val server: RelayServer, private val transcoder: RelayTranscoder) : DecoderSink {
  @Volatile
  var transcoderFailures = 0L
    private set

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    val askSwitch = server.submitDrone(unit, description)
    guarded { transcoder.offer(unit, description) }
    if (askSwitch) {
      guarded { server.askSteadySwitch() }
    }
  }

  override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    server.keepKey(unit, description)
    guarded { transcoder.keepKey(unit, description) }
  }

  override fun reset() {
    server.reset()
    guarded { transcoder.reset() }
  }

  override fun newStream() {
    server.newStream()
  }

  override fun status(): DecoderStatus = DecoderStatus()

  private inline fun guarded(block: () -> Unit) {
    try {
      block()
    } catch (error: Throwable) {
      transcoderFailures += 1
    }
  }
}
