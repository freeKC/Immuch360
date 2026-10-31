package me.albemala.native_video_player.platform_interface

data class VideoSource(
    val path: String,
    val type: VideoSourceType,
    val headers: Map<String, String>,
    // Immuch360: where the video starts, in ms, null for its start
    val startPositionMs: Long? = null,
) {
    companion object {
        fun from(map: Map<*, *>): VideoSource? {
            val path = map["path"] as? String
                ?: return null
            val typeValue = map["type"] as? String
                ?: return null
            val headersAny = map["headers"] as? Map<*, *>
                ?: return null
            val headers =
                    headersAny.entries
                    .filter { it.key is String && it.value is String }
                    .associate { (it.key as String) to (it.value as String) }
            val type = VideoSourceType.entries
                .firstOrNull {
                    it.value == typeValue
                }
                ?: return null
            val start = (map["startPositionMs"] as? Number)?.toLong()?.takeIf { it > 0 }
            return VideoSource(
                path,
                type,
                headers,
                start,
            )
        }
    }
}
