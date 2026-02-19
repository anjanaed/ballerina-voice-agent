import { useState, useRef, useEffect, useCallback } from 'react';
import { encodeWAV } from '../utils/wavEncoder';

interface UseAudioProps {
  onSilence: (data: ArrayBuffer) => void;
  silenceThreshold?: number; // Duration in ms
  volumeThreshold?: number; // Level to consider as "sound"
}

export function useAudio({ onSilence, silenceThreshold = 4000, volumeThreshold = 0.005 }: UseAudioProps) {
  const [isRecording, setIsRecording] = useState(false);
  const [volume, setVolume] = useState(0);
  
  const audioContextRef = useRef<AudioContext | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const processorRef = useRef<ScriptProcessorNode | null>(null);
  const silenceTimerRef = useRef<any>(null);
  const chunksRef = useRef<Float32Array[]>([]);
  
  // Use a ref for onSilence to avoid unnecessary re-renders/stops
  const onSilenceRef = useRef(onSilence);
  onSilenceRef.current = onSilence;

  const flushAudio = useCallback(() => {
    if (chunksRef.current.length === 0) return;

    // Flatten chunks
    const totalLength = chunksRef.current.reduce((acc, chunk) => acc + chunk.length, 0);
    const flattened = new Float32Array(totalLength);
    let offset = 0;
    for (const chunk of chunksRef.current) {
      flattened.set(chunk, offset);
      offset += chunk.length;
    }

    // Reset chunks early to avoid duplicates
    chunksRef.current = [];

    const wavBuffer = encodeWAV(flattened, audioContextRef.current?.sampleRate || 16000);
    onSilenceRef.current(wavBuffer);
    
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  }, []);

  const stopRecording = useCallback(() => {
    // Send any remaining data before stopping
    flushAudio();

    if (streamRef.current) {
      streamRef.current.getTracks().forEach(track => track.stop());
      streamRef.current = null;
    }
    if (processorRef.current) {
      processorRef.current.disconnect();
      processorRef.current = null;
    }
    if (audioContextRef.current) {
      if (audioContextRef.current.state !== 'closed') {
        audioContextRef.current.close();
      }
      audioContextRef.current = null;
    }
    setIsRecording(false);
    
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current);
      silenceTimerRef.current = null;
    }
  }, [flushAudio]);

  const startRecording = async () => {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      streamRef.current = stream;

      const audioContext = new AudioContext({ sampleRate: 16000 });
      audioContextRef.current = audioContext;

      const source = audioContext.createMediaStreamSource(stream);
      const processor = audioContext.createScriptProcessor(4096, 1, 1);
      processorRef.current = processor;

      source.connect(processor);
      processor.connect(audioContext.destination);

      setIsRecording(true);
      chunksRef.current = [];

      processor.onaudioprocess = (e) => {
        const inputData = e.inputBuffer.getChannelData(0);
        const currentData = new Float32Array(inputData);
        chunksRef.current.push(currentData);

        // Calculate average volume
        let sum = 0;
        for (let i = 0; i < currentData.length; i++) {
          sum += Math.abs(currentData[i]);
        }
        const avgVolume = sum / currentData.length;
        setVolume(avgVolume);

        if (avgVolume > volumeThreshold) {
          // Sound detected, clear timer
          if (silenceTimerRef.current) {
            clearTimeout(silenceTimerRef.current);
            silenceTimerRef.current = null;
          }
        } else {
          // Silence detected, start timer if not already running
          if (!silenceTimerRef.current) {
            silenceTimerRef.current = setTimeout(() => {
              // Automatically stop when silence threshold is reached
              stopRecording();
            }, silenceThreshold);
          }
        }
      };
    } catch (err) {
      console.error('Error starting recording:', err);
    }
  };

  useEffect(() => {
    return () => {
      // Basic cleanup for unmount
      if (streamRef.current) {
        streamRef.current.getTracks().forEach(track => track.stop());
      }
    };
  }, []);

  return { isRecording, volume, startRecording, stopRecording };
}
