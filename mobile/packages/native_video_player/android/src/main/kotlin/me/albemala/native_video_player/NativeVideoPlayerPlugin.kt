package me.albemala.native_video_player

import android.content.Context
import androidx.annotation.NonNull
import androidx.media3.common.PlaybackException
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy

import io.flutter.embedding.engine.plugins.FlutterPlugin

class NativeVideoPlayerPlugin : FlutterPlugin {
    companion object {
        var dataSourceFactory: ((Map<String, String>) -> DataSource.Factory)? = null

        // Immuch360: the audio language each new player prefers (the one the user picked last), and where a pick of
        // the user goes (null for a track without a language), so that the app keeps one choice for all its players
        var preferredAudioLanguage: (() -> String?)? = null
        var onAudioLanguageChosen: ((String?) -> Unit)? = null

        // Immuch360: what the app sends Flutter for an error of a player instead of the text of Media3 ("Player stuck
        // playing with no progress for 10000 ms"), null to send that text as before
        var errorToken: ((PlaybackException, ExoPlayer) -> String?)? = null

        // Immuch360: makes the player of each view with what the app measures of its link (see PlayerSetup), null for
        // a player of Media3's defaults
        var playerSetup: ((Context) -> PlayerSetup)? = null
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val factory = NativeVideoPlayerViewFactory(binding.binaryMessenger)
        binding.platformViewRegistry.registerViewFactory(NativeVideoPlayerViewFactory.id, factory)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}

/**
 * Immuch360: the player of a view as the app makes it, with its link: the load control that starts a streamed video
 * from the measured link, and what Flutter is told of that link while the video loads (onLinkChanged)
 */
interface PlayerSetup {
    val player: ExoPlayer

    /** The policy of the loads of a network video, null for Media3's */
    val loadErrorPolicy: LoadErrorHandlingPolicy?

    /** A new video loads: what was measured of the one before goes */
    fun onLoad()

    /** What Flutter is told of the link now, null for nothing */
    fun link(): Map<String, Any?>?

    /** The token of the error to send Flutter when the player waits with a decoder that gives no picture, else null */
    fun stuckError(): String?

    /** The view goes */
    fun release()
}
