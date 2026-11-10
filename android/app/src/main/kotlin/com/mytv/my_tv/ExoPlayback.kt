package com.mytv.my_tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackGroup
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Playback through Android's own ExoPlayer, drawn into a SurfaceView.
 *
 * Why this exists next to libmpv: on a car head unit mpv stutters badly on a
 * 1080p H.264 channel even with hardware decoding, while a native IPTV app
 * plays the same channel faultlessly. The difference is the path to the
 * screen. mpv has to deliver frames to Flutter as a texture, which the GPU
 * then composites; a SurfaceView is handed to the display controller directly
 * and never passes through Flutter at all.
 *
 * Only the engine changes. Every control, overlay and list stays in Flutter,
 * drawn above this surface.
 */
@UnstableApi
object ExoPlayback {
    private const val METHODS = "com.mytv.my_tv/exo"
    private const val EVENTS = "com.mytv.my_tv/exo_events"
    const val VIEW_TYPE = "com.mytv.my_tv/exo_view"

    private val main = Handler(Looper.getMainLooper())

    private var player: ExoPlayer? = null
    private var trackSelector: DefaultTrackSelector? = null
    private var events: EventChannel.EventSink? = null

    /** Views currently on screen. Normally one; a rebuild can briefly make two. */
    private val views = mutableSetOf<PlayerView>()

    /** Which codec the hardware picked, for the playback-info overlay. */
    private var decoderName: String? = null

    private var ticker: Runnable? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, METHODS).setMethodCallHandler { call, result ->
            try {
                handle(context, call.method, call, result)
            } catch (e: Throwable) {
                result.error("exo_failed", e.message, null)
            }
        }

        EventChannel(messenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            },
        )
    }

    fun viewFactory(): PlatformViewFactory = Factory()

    private fun handle(
        context: Context,
        method: String,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (method) {
            "create" -> {
                create(
                    context,
                    bufferAheadSeconds = call.argument<Int>("bufferAheadSeconds") ?: 30,
                    bufferAheadBytes = call.argument<Int>("bufferAheadBytes") ?: 0,
                )
                result.success(true)
            }

            "open" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("no_url", "A stream URL is required.", null)
                    return
                }
                open(
                    context,
                    url,
                    headers = call.argument<Map<String, String>>("headers") ?: emptyMap(),
                    startAtMs = (call.argument<Int>("startAtMs") ?: 0).toLong(),
                )
                result.success(true)
            }

            "playOrPause" -> {
                player?.let { it.playWhenReady = !it.playWhenReady }
                result.success(null)
            }

            "play" -> {
                player?.play()
                result.success(null)
            }

            "pause" -> {
                player?.pause()
                result.success(null)
            }

            "seek" -> {
                val ms = (call.argument<Int>("positionMs") ?: 0).toLong()
                player?.seekTo(ms)
                result.success(null)
            }

            "setVolume" -> {
                // Dart speaks 0-100, ExoPlayer 0-1.
                val percent = call.argument<Double>("volume") ?: 100.0
                player?.volume = (percent / 100.0).coerceIn(0.0, 1.0).toFloat()
                result.success(null)
            }

            "selectTrack" -> {
                selectTrack(
                    kind = call.argument<String>("kind") ?: "audio",
                    id = call.argument<String>("id") ?: "auto",
                )
                result.success(null)
            }

            "dispose" -> {
                release()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun create(context: Context, bufferAheadSeconds: Int, bufferAheadBytes: Int) {
        release()

        // The same read-ahead the mpv engine uses, so a dip in a weak
        // connection is ridden out rather than stopping playback. ExoPlayer
        // wants it in milliseconds, and insists maxBuffer >= minBuffer.
        val aheadMs = (bufferAheadSeconds.coerceIn(5, 600)) * 1000
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                aheadMs,
                aheadMs.coerceAtLeast(DefaultLoadControl.DEFAULT_MAX_BUFFER_MS),
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_MS,
                DefaultLoadControl.DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
            )
            .apply {
                if (bufferAheadBytes > 0) setTargetBufferBytes(bufferAheadBytes)
            }
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()

        val selector = DefaultTrackSelector(context)
        trackSelector = selector

        // EXTENSION_RENDERER_MODE_OFF keeps decoding on the hardware codecs.
        // Falling back to a software decoder is what we are trying to avoid.
        val renderers = DefaultRenderersFactory(context)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
            .setEnableDecoderFallback(true)

        val created = ExoPlayer.Builder(context, renderers)
            .setLoadControl(loadControl)
            .setTrackSelector(selector)
            .build()

        created.addListener(listener)
        created.addAnalyticsListener(analytics)
        created.playWhenReady = true
        player = created

        views.forEach { it.player = created }
        startTicker()
    }

    private fun open(
        context: Context,
        url: String,
        headers: Map<String, String>,
        startAtMs: Long,
    ) {
        val active = player ?: run {
            create(context, 30, 0)
            player ?: return
        }

        val userAgent = headers["User-Agent"] ?: headers["user-agent"]
        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(20_000)
            .setReadTimeoutMs(20_000)
            .setDefaultRequestProperties(headers.filterKeys { !it.equals("User-Agent", true) })
        if (!userAgent.isNullOrEmpty()) http.setUserAgent(userAgent)

        // DefaultDataSource adds file:// and content:// on top of HTTP, which
        // is what makes a downloaded film play with no network at all.
        val sources = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http))

        decoderName = null

        active.setMediaSource(sources.createMediaSource(MediaItem.fromUri(url)))
        if (startAtMs > 0) active.seekTo(startAtMs)
        active.prepare()
        active.play()
    }

    private fun selectTrack(kind: String, id: String) {
        val active = player ?: return
        val type = if (kind == "text") C.TRACK_TYPE_TEXT else C.TRACK_TYPE_AUDIO

        val builder = active.trackSelectionParameters.buildUpon()
        builder.clearOverridesOfType(type)

        when (id) {
            "no" -> builder.setTrackTypeDisabled(type, true)
            "auto" -> builder.setTrackTypeDisabled(type, false)
            else -> {
                builder.setTrackTypeDisabled(type, false)
                val group = groupFor(active.currentTracks, type, id)
                if (group != null) {
                    builder.addOverride(TrackSelectionOverride(group.first, group.second))
                }
            }
        }
        active.trackSelectionParameters = builder.build()
    }

    /** Ids are "type:group:track", which survives a round trip through Dart. */
    private fun groupFor(
        tracks: Tracks,
        type: Int,
        id: String,
    ): Pair<TrackGroup, Int>? {
        var index = 0
        for (group in tracks.groups) {
            if (group.type != type) continue
            for (track in 0 until group.length) {
                if (idFor(type, index, track) == id) {
                    return group.mediaTrackGroup to track
                }
            }
            index++
        }
        return null
    }

    private fun idFor(type: Int, group: Int, track: Int): String {
        val prefix = if (type == C.TRACK_TYPE_TEXT) "text" else "audio"
        return "$prefix:$group:$track"
    }

    // --- Events ---------------------------------------------------------------

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            send(mapOf("event" to "playing", "value" to isPlaying))
        }

        override fun onPlaybackStateChanged(state: Int) {
            send(mapOf("event" to "buffering", "value" to (state == Player.STATE_BUFFERING)))
            val duration = player?.duration ?: C.TIME_UNSET
            if (duration != C.TIME_UNSET && duration > 0) {
                send(mapOf("event" to "duration", "valueMs" to duration))
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            send(
                mapOf(
                    "event" to "error",
                    "message" to (error.message ?: error.errorCodeName),
                ),
            )
        }

        override fun onVideoSizeChanged(size: VideoSize) {
            send(
                mapOf(
                    "event" to "size",
                    "width" to size.width,
                    "height" to size.height,
                ),
            )
        }

        override fun onTracksChanged(tracks: Tracks) {
            val audio = mutableListOf<Map<String, Any?>>()
            val text = mutableListOf<Map<String, Any?>>()
            var activeAudio = "auto"
            var activeText = "no"

            var audioGroup = 0
            var textGroup = 0
            for (group in tracks.groups) {
                val type = group.type
                if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_TEXT) continue
                val index = if (type == C.TRACK_TYPE_AUDIO) audioGroup else textGroup
                for (track in 0 until group.length) {
                    val format = group.getTrackFormat(track)
                    val id = idFor(type, index, track)
                    val entry = mapOf(
                        "id" to id,
                        "title" to (format.label ?: format.language ?: "Track ${track + 1}"),
                        "language" to format.language,
                    )
                    if (type == C.TRACK_TYPE_AUDIO) {
                        audio.add(entry)
                        if (group.isTrackSelected(track)) activeAudio = id
                    } else {
                        text.add(entry)
                        if (group.isTrackSelected(track)) activeText = id
                    }
                }
                if (type == C.TRACK_TYPE_AUDIO) audioGroup++ else textGroup++
            }

            send(
                mapOf(
                    "event" to "tracks",
                    "audio" to audio,
                    "text" to text,
                    "activeAudio" to activeAudio,
                    "activeText" to activeText,
                ),
            )
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoder: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            decoderName = decoder
        }
    }

    /** Position, and the figures the playback-info overlay reads. */
    private fun startTicker() {
        stopTicker()
        val tick = object : Runnable {
            override fun run() {
                val active = player
                if (active != null) {
                    send(
                        mapOf(
                            "event" to "tick",
                            "positionMs" to active.currentPosition.coerceAtLeast(0),
                            "durationMs" to
                                if (active.duration == C.TIME_UNSET) 0L else active.duration,
                            "decoder" to decoderName,
                            "codec" to
                                active.videoFormat?.sampleMimeType?.substringAfter('/'),
                            "dropped" to (active.videoDecoderCounters?.droppedBufferCount ?: 0),
                        ),
                    )
                }
                main.postDelayed(this, 500)
            }
        }
        ticker = tick
        main.post(tick)
    }

    private fun stopTicker() {
        ticker?.let { main.removeCallbacks(it) }
        ticker = null
    }

    private fun send(payload: Map<String, Any?>) {
        main.post { events?.success(payload) }
    }

    private fun release() {
        stopTicker()
        views.forEach { it.player = null }
        player?.let {
            it.removeListener(listener)
            it.release()
        }
        player = null
        trackSelector = null
        decoderName = null
    }

    // --- The surface ----------------------------------------------------------

    private class Factory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, id: Int, args: Any?): PlatformView =
            Surface(context)
    }

    private class Surface(context: Context) : PlatformView {
        private val view = PlayerView(context).apply {
            // Flutter draws every control, so ExoPlayer's own must stay away.
            useController = false
            resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
            setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
            setKeepContentOnPlayerReset(true)
            player = ExoPlayback.player
        }

        init {
            ExoPlayback.views.add(view)
        }

        override fun getView(): View = view

        override fun dispose() {
            ExoPlayback.views.remove(view)
            view.player = null
        }
    }
}
