package me.albemala.native_video_player.platform_interface

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

interface NativeVideoPlayerApiDelegate {
    fun loadVideoSource(videoSource: VideoSource)
    fun getVideoInfo(): VideoInfo
    fun getPlaybackPosition(): Long
    fun play()
    fun pause()
    fun stop()
    fun isPlaying(): Boolean
    fun seekTo(position: Int)
    fun setPlaybackSpeed(speed: Double)
    fun setVolume(volume: Double)
    fun setLoop(loop: Boolean)

    // Immuch360: the audio and subtitle tracks
    fun getTracks(localeTag: String?): List<Map<String, Any?>>
    fun selectTrack(type: String, group: Int, track: Int): Boolean
    fun disableTracks(type: String)
}

const val invalidArgumentsErrorCode = "invalid_argument"
const val invalidArgumentsErrorMessage = "Invalid arguments"

class NativeVideoPlayerApi(
    messenger: BinaryMessenger,
    viewId: Int
) : MethodChannel.MethodCallHandler {

    var delegate: NativeVideoPlayerApiDelegate? = null

    private val channel: MethodChannel

    init {
        val name = "me.albemala.native_video_player.api.${viewId}"
        channel = MethodChannel(messenger, name)
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    fun onPlaybackReady() {
        channel.invokeMethod("onPlaybackReady", null)
    }

    fun onPlaybackEnded() {
        channel.invokeMethod("onPlaybackEnded", null)
    }

    fun onPlaybackPositionChanged(position: Long) {
        channel.invokeMethod("onPlaybackPositionChanged", position)
    }

    fun onError(error: Throwable) {
        channel.invokeMethod("onError", error.message)
    }

    // Immuch360: the tracks of the video changed (a video loaded, a track picked)
    fun onTracksChanged() {
        channel.invokeMethod("onTracksChanged", null)
    }

    override fun onMethodCall(methodCall: MethodCall, result: MethodChannel.Result) {
        when (methodCall.method) {
            "loadVideoSource" -> {
                val videoSourceAsMap = methodCall.arguments as? Map<*, *>
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                val videoSource = VideoSource.from(videoSourceAsMap)
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.loadVideoSource(videoSource)
                result.success(null)
            }
            "getVideoInfo" -> {
                result.success(delegate?.getVideoInfo()?.toMap())
            }
            "getPlaybackPosition" -> {
                result.success(delegate?.getPlaybackPosition())
            }
            "play" -> {
                delegate?.play()
                result.success(null)
            }
            "pause" -> {
                delegate?.pause()
                result.success(null)
            }
            "stop" -> {
                delegate?.stop()
                result.success(null)
            }
            "isPlaying" -> {
                val playing = delegate?.isPlaying()
                result.success(playing)
            }
            "seekTo" -> {
                val position = methodCall.arguments as? Int
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.seekTo(position)
                result.success(null)
            }
            "setPlaybackSpeed" -> {
                val speed = methodCall.arguments as? Double
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.setPlaybackSpeed(speed)
                result.success(null)
            }
            "setVolume" -> {
                val volume = methodCall.arguments as? Double
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.setVolume(volume)
                result.success(null)
            }
            "setLoop" -> {
                val loop = methodCall.arguments as? Boolean
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.setLoop(loop)
                result.success(null)
            }
            // Immuch360: the audio and subtitle tracks
            "getTracks" -> {
                result.success(delegate?.getTracks(methodCall.arguments as? String) ?: emptyList<Map<String, Any?>>())
            }
            "selectTrack" -> {
                val arguments = methodCall.arguments as? Map<*, *>
                val type = arguments?.get("type") as? String
                val group = (arguments?.get("group") as? Number)?.toInt()
                val track = (arguments?.get("track") as? Number)?.toInt()
                if (type == null || group == null || track == null) {
                    return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                }
                result.success(delegate?.selectTrack(type, group, track) ?: false)
            }
            "disableTracks" -> {
                val type = methodCall.arguments as? String
                    ?: return result.error(invalidArgumentsErrorCode, invalidArgumentsErrorMessage, null)
                delegate?.disableTracks(type)
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }
    }
}
