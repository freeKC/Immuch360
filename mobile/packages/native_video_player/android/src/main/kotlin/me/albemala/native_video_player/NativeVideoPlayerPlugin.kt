package me.albemala.native_video_player

import androidx.annotation.NonNull
import androidx.media3.datasource.DataSource

import io.flutter.embedding.engine.plugins.FlutterPlugin

class NativeVideoPlayerPlugin : FlutterPlugin {
    companion object {
        var dataSourceFactory: ((Map<String, String>) -> DataSource.Factory)? = null

        // Immuch360: the audio language each new player prefers (the one the user picked last), and where a pick of
        // the user goes (null for a track without a language), so that the app keeps one choice for all its players
        var preferredAudioLanguage: (() -> String?)? = null
        var onAudioLanguageChosen: ((String?) -> Unit)? = null
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val factory = NativeVideoPlayerViewFactory(binding.binaryMessenger)
        binding.platformViewRegistry.registerViewFactory(NativeVideoPlayerViewFactory.id, factory)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
