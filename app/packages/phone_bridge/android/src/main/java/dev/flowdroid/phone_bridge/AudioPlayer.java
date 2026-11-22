package dev.flowdroid.phone_bridge;

import android.media.AudioAttributes;
import android.media.MediaPlayer;

import io.flutter.plugin.common.MethodChannel;

/** Plays one spoken clip (a file or a URL) and answers when it has finished. */
final class AudioPlayer {
    private static MediaPlayer current;
    private static MethodChannel.Result waiting;

    private AudioPlayer() {}

    static synchronized void play(String source, MethodChannel.Result result) {
        stop();
        MediaPlayer player = new MediaPlayer();
        current = player;
        waiting = result;
        try {
            player.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build());
            player.setDataSource(source);
            player.setOnPreparedListener(MediaPlayer::start);
            player.setOnCompletionListener(p -> finish(p, null));
            player.setOnErrorListener((p, what, extra) -> {
                finish(p, "the audio could not be played (" + what + "/" + extra + ")");
                return true;
            });
            player.prepareAsync();
        } catch (Exception e) {
            finish(player, "the audio could not be played: " + e.getMessage());
        }
    }

    /** Stops what is playing; its caller hears that it ended. */
    static synchronized void stop() {
        if (current != null) finish(current, null);
    }

    private static synchronized void finish(MediaPlayer player, String error) {
        if (player != current) return;
        current = null;
        MethodChannel.Result result = waiting;
        waiting = null;
        try {
            player.release();
        } catch (RuntimeException ignored) {
            // Already released.
        }
        if (result != null) result.success(error);
    }
}
