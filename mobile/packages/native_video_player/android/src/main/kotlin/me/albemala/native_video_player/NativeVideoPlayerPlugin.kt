package me.albemala.native_video_player

import androidx.annotation.NonNull
import androidx.media3.common.PlaybackException
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer

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
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val factory = NativeVideoPlayerViewFactory(binding.binaryMessenger)
        binding.platformViewRegistry.registerViewFactory(NativeVideoPlayerViewFactory.id, factory)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
