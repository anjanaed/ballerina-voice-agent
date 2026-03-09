import { useState, useRef, useCallback } from 'react';
import { encodeWAV } from '../utils/wavEncoder';

/** Convert a Float32Array audio chunk to Int16 PCM ArrayBuffer */
function float32ToInt16(float32: Float32Array): ArrayBuffer {
  const buf = new ArrayBuffer(float32.length * 2);
  const view = new DataView(buf);
  for (let i = 0; i < float32.length; i++) {
    const s = Math.max(-1, Math.min(1, float32[i]));
    view.setInt16(i * 2, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
  }
  return buf;
}

interface UseAudioProps {
  onSilence: (data: ArrayBuffer) => void;
  onChunk?: (pcm16: ArrayBuffer) => void;  // stream each PCM-16 chunk in real time
  silenceThreshold?: number; // ms of silence before auto-stop
  volumeThreshold?: number;  // RMS level to consider as "speech"
}

export function useAudio({
  onSilence,
  onChunk,
  silenceThreshold = 4000,
  volumeThreshold = 0.005,
}: UseAudioProps) {
  const [isRecording, setIsRecording] = useState(false);
  const [volume, setVolume] = useState(0);
  const [silenceSecondsLeft, setSilenceSecondsLeft] = useState<number | null>(null);

  const audioContextRef = useRef<AudioContext | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const sourceRef = useRef<MediaStreamAudioSourceNode | null>(null);
  const silentGainRef = useRef<GainNode | null>(null);  // muted sink — keeps graph alive
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const countdownIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const silenceStartRef = useRef<number | null>(null);
  const chunksRef = useRef<Float32Array[]>([]);
  const isRecordingRef = useRef(false);
  const hasSpeechRef = useRef(false);

  const onSilenceRef = useRef(onSilence);
  onSilenceRef.current = onSilence;

  const onChunkRef = useRef(onChunk);
  onChunkRef.current = onChunk;

  const clearSilenceTimer = useCallback(() => {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
    if (countdownIntervalRef.current) {
      clearInterval(countdownIntervalRef.current);
      countdownIntervalRef.current = null;
    }
    silenceStartRef.current = null;
    setSilenceSecondsLeft(null);
  }, []);

  const flushAudio = useCallback(() => {
    if (chunksRef.current.length === 0) return;

    // Don't trigger the pipeline if the user never actually spoke.
    // For the Realtime path this prevents a spurious stream_end that would
    // leave the UI stuck in "Thinking…" with no VAD response coming back.
    if (!hasSpeechRef.current) {
      chunksRef.current = [];
      clearSilenceTimer();
      return;
    }

    const chunks = chunksRef.current;
    chunksRef.current = [];

    clearSilenceTimer();

    const totalLength = chunks.reduce((acc, c) => acc + c.length, 0);
    const flattened = new Float32Array(totalLength);
    let offset = 0;
    for (const chunk of chunks) {
      flattened.set(chunk, offset);
      offset += chunk.length;
    }

    // Read sampleRate before teardown closes the context
    const sampleRate = audioContextRef.current?.sampleRate ?? 16000;
    const wavBuffer = encodeWAV(flattened, sampleRate);
    onSilenceRef.current(wavBuffer);
  }, [clearSilenceTimer]);

  const teardown = useCallback(() => {
    isRecordingRef.current = false;
    hasSpeechRef.current = false;

    clearSilenceTimer();

    if (processorRef.current) {
      processorRef.current.onaudioprocess = null;
      processorRef.current.disconnect();
      processorRef.current = null;
    }
    if (sourceRef.current) {
      sourceRef.current.disconnect();
      sourceRef.current = null;
    }
    if (silentGainRef.current) {
      silentGainRef.current.disconnect();
      silentGainRef.current = null;
    }
    if (streamRef.current) {
      streamRef.current.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
    }
    if (audioContextRef.current) {
      if (audioContextRef.current.state !== 'closed') {
        audioContextRef.current.close();
      }
      audioContextRef.current = null;
    }

    setIsRecording(false);
    setVolume(0);
    setSilenceSecondsLeft(null);
  }, [clearSilenceTimer]);

  const stopRecording = useCallback(() => {
    if (!isRecordingRef.current) return;
    flushAudio();
    teardown();
  }, [flushAudio, teardown]);

  const startRecording = useCallback(async () => {
    if (isRecordingRef.current) return;

    try {
      // Accuracy improvement: Disable all browser-side audio processing. 
      // Echo cancellation, noise suppression, and auto-gain alter the raw waveform 
      // before it even reaches our processing node, which degrades Whisper accuracy.
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
          channelCount: 1,
          sampleRate: 24000, // OpenAI Realtime API requires 24kHz PCM16
        },
      });
      streamRef.current = stream;

      const audioContext = new AudioContext({ sampleRate: 24000 }); // must match Realtime API
      audioContextRef.current = audioContext;

      const source = audioContext.createMediaStreamSource(stream);
      sourceRef.current = source;

      const processor = audioContext.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      // Connect processor to a MUTED GainNode (gain=0) rather than directly to destination. 
      // This keeps the ScriptProcessorNode alive in the audio graph (required by spec) 
      // without routing mic audio to the speakers, which would cause signal corruption.
      const silentGain = audioContext.createGain();
      silentGain.gain.value = 0;
      silentGainRef.current = silentGain;

      source.connect(processor);
      processor.connect(silentGain);
      silentGain.connect(audioContext.destination);

      chunksRef.current = [];
      isRecordingRef.current = true;
      hasSpeechRef.current = false;
      setIsRecording(true);

      processor.onaudioprocess = (e) => {
        if (!isRecordingRef.current) return;

        const inputData = e.inputBuffer.getChannelData(0);
        const chunkCopy = new Float32Array(inputData);
        chunksRef.current.push(chunkCopy);

        // Stream chunk to server in real time as Int16 PCM
        if (onChunkRef.current) {
          onChunkRef.current(float32ToInt16(chunkCopy));
        }

        let sum = 0;
        for (let i = 0; i < inputData.length; i++) {
          sum += Math.abs(inputData[i]);
        }
        const avgVolume = sum / inputData.length;
        setVolume(avgVolume);

        if (avgVolume > volumeThreshold) {
          hasSpeechRef.current = true;
          clearSilenceTimer();
        } else if (hasSpeechRef.current) {
          if (!silenceTimerRef.current) {
            silenceStartRef.current = Date.now();

            countdownIntervalRef.current = setInterval(() => {
              if (silenceStartRef.current !== null) {
                const elapsed = Date.now() - silenceStartRef.current;
                const remaining = Math.ceil((silenceThreshold - elapsed) / 1000);
                setSilenceSecondsLeft(remaining > 0 ? remaining : 0);
              }
            }, 200);

            silenceTimerRef.current = setTimeout(() => {
              stopRecording();
            }, silenceThreshold);
          }
        }
      };
    } catch (err) {
      console.error('Error starting recording:', err);
      teardown();
    }
  }, [silenceThreshold, volumeThreshold, clearSilenceTimer, stopRecording, teardown]);

  return { isRecording, volume, silenceSecondsLeft, startRecording, stopRecording };
}
