package me.albemala.native_video_player.platform_interface

data class VideoSource(
    val path: String,
    val type: VideoSourceType,
    val headers: Map<String, String>,
    // Immuch360: where the video starts, in ms, null for its start
    val startPositionMs: Long? = null,
    // Immuch360: the side files of subtitles of the video, listed as subtitle tracks next to its own (patch 3)
    val subtitles: List<VideoSubtitle> = emptyList(),
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
            val subtitles = (map["subtitles"] as? List<*>).orEmpty()
                .mapNotNull { (it as? Map<*, *>)?.let(VideoSubtitle::from) }
            return VideoSource(
                path,
                type,
                headers,
                start,
                subtitles,
            )
        }
    }
}

/**
 * Immuch360: a side file of subtitles (a sidecar the app's media bridge serves over http://127.0.0.1): where it is,
 * its MIME type ("application/x-subrip"), language and name, and the id its track gets in Media3 (Format.id), which
 * the app tells it by
 */
data class VideoSubtitle(
    val uri: String,
    val mimeType: String,
    val language: String? = null,
    val label: String? = null,
    val id: String? = null,
) {
    companion object {
        /** The side file of [map] as Dart sends it, null without its address or its type */
        fun from(map: Map<*, *>): VideoSubtitle? {
            val uri = (map["uri"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            val mimeType = (map["mimeType"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            return VideoSubtitle(
                uri,
                mimeType,
                map["language"] as? String,
                map["label"] as? String,
                map["id"] as? String,
            )
        }
    }
}
