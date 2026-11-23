package dev.flowdroid.phone_bridge;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * Speech to text without a screen: Android's speech recognizer listening
 * through the microphone. (With FlowDroid on screen the plugin shows Android's
 * own speech dialog instead, which needs no microphone permission.)
 */
final class SpeechActions {
    private SpeechActions() {}

    static Intent recognizeIntent(String language, String prompt) {
        Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
        if (language != null && !language.isEmpty()) intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, language);
        if (prompt != null && !prompt.isEmpty()) intent.putExtra(RecognizerIntent.EXTRA_PROMPT, prompt);
        return intent;
    }

    /** The first result in a recognizer's bundle or result intent, as `{text, confidence}`. */
    static Map<String, Object> resultOf(ArrayList<String> texts, float[] scores) {
        Map<String, Object> out = new HashMap<>();
        out.put("text", texts == null || texts.isEmpty() || texts.get(0) == null ? "" : texts.get(0));
        out.put("confidence", scores == null || scores.length == 0 || scores[0] < 0 ? null : (double) scores[0]);
        return out;
    }

    /** Listens for up to [maxMs] and calls [done] once, on the main thread. */
    static void listen(Context context, String language, long maxMs, Consumer<Map<String, Object>> done) {
        Handler main = new Handler(Looper.getMainLooper());
        main.post(() -> {
            if (!SpeechRecognizer.isRecognitionAvailable(context)) {
                done.accept(error("this phone has no speech recognition service"));
                return;
            }
            if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                done.accept(error("FlowDroid may not use the microphone yet: allow it in Settings → Phone access"));
                return;
            }
            SpeechRecognizer recognizer = SpeechRecognizer.createSpeechRecognizer(context);
            AtomicBoolean finished = new AtomicBoolean(false);
            Consumer<Map<String, Object>> finish = answer -> {
                if (!finished.compareAndSet(false, true)) return;
                main.post(recognizer::destroy);
                done.accept(answer);
            };
            recognizer.setRecognitionListener(new RecognitionListener() {
                @Override public void onResults(Bundle results) {
                    finish.accept(resultOf(
                        results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION),
                        results.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)));
                }

                @Override public void onError(int code) {
                    switch (code) {
                        case SpeechRecognizer.ERROR_NO_MATCH:
                        case SpeechRecognizer.ERROR_SPEECH_TIMEOUT:
                            // Nothing was said: an empty answer, not a failure.
                            finish.accept(resultOf(null, null));
                            break;
                        case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS:
                            finish.accept(error("FlowDroid may not use the microphone yet: allow it in Settings → Phone access"));
                            break;
                        case SpeechRecognizer.ERROR_NETWORK:
                        case SpeechRecognizer.ERROR_NETWORK_TIMEOUT:
                            finish.accept(error("speech recognition needs the internet on this phone"));
                            break;
                        case SpeechRecognizer.ERROR_AUDIO:
                            finish.accept(error("the microphone is not available (Android blocks it for apps in the background on newer versions; run this step with FlowDroid open)"));
                            break;
                        default:
                            finish.accept(error("speech recognition failed (code " + code + ")"));
                    }
                }

                @Override public void onReadyForSpeech(Bundle params) {}
                @Override public void onBeginningOfSpeech() {}
                @Override public void onRmsChanged(float rmsdB) {}
                @Override public void onBufferReceived(byte[] buffer) {}
                @Override public void onEndOfSpeech() {}
                @Override public void onPartialResults(Bundle partialResults) {}
                @Override public void onEvent(int eventType, Bundle params) {}
            });
            try {
                recognizer.startListening(recognizeIntent(language, null));
            } catch (RuntimeException e) {
                finish.accept(error("could not start listening: " + e.getMessage()));
                return;
            }
            main.postDelayed(() -> {
                if (!finished.get()) recognizer.stopListening();
            }, Math.max(1000, maxMs));
            // If the recognizer never answers after stopping, give up.
            main.postDelayed(() -> finish.accept(resultOf(null, null)), Math.max(1000, maxMs) + 10_000);
        });
    }

    private static Map<String, Object> error(String message) {
        Map<String, Object> out = new HashMap<>();
        out.put("error", message);
        return out;
    }
}
