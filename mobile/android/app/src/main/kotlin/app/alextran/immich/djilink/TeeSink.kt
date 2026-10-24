package app.alextran.immich.djilink

/**
 * The tee of p2/design-stage2b.md, 3.2: every unit the phone decodes, with the description it decodes it with, goes to
 * the phone's own decoder feed and to the relay. The bytes are shared, never copied: an access unit is never written
 * after it was assembled. The relay is called after the feed and inside a catch, so that the phone's own picture never
 * depends on it; a failure there is only counted.
 */
class TeeSink(private val feed: DecoderSink, private val relay: DecoderSink) : DecoderSink {
  @Volatile
  var relayFailures = 0L
    private set

  override fun submit(unit: AccessUnit, description: ResolvedDescription) {
    feed.submit(unit, description)
    guarded { relay.submit(unit, description) }
  }

  /** Only the feed keeps it: the relay keeps its own, from the units it relays */
  override fun keepKey(unit: AccessUnit, description: ResolvedDescription) {
    feed.keepKey(unit, description)
  }

  override fun reset() {
    feed.reset()
    guarded { relay.reset() }
  }

  override fun newStream() {
    feed.newStream()
    guarded { relay.newStream() }
  }

  override fun status(): DecoderStatus = feed.status()

  private inline fun guarded(block: () -> Unit) {
    try {
      block()
    } catch (error: Throwable) {
      relayFailures += 1
    }
  }
}
