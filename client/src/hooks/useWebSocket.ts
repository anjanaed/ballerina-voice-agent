import { useEffect, useRef, useState, useCallback } from 'react';

export type Message = {
  role: 'user' | 'assistant';
  text: string;
};

export function useWebSocket(url: string) {
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(true);
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [messages, setMessages] = useState<Message[]>([]);  
  const socketRef = useRef<WebSocket | null>(null);
  const audioPlayerRef = useRef<HTMLAudioElement | null>(null);
  const pendingBlobUrlRef = useRef<string | null>(null);

  useEffect(() => {
    let socket: WebSocket | null = null;
    let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
    let isMounted = true;

    const connect = () => {
      if (!isMounted) return;

      setIsConnecting(true);
      socket = new WebSocket(url);
      socket.binaryType = 'arraybuffer';
      socketRef.current = socket;

      socket.onopen = () => {
        if (isMounted) {
          setIsConnected(true);
          setIsConnecting(false);
          console.log('WebSocket connected');
        }
      };

      socket.onclose = (ev) => {
        if (!isMounted) return;
        console.log('WebSocket closed, code:', ev.code, 'reason:', ev.reason);
        setIsConnected(false);
        setIsConnecting(false);
        setIsProcessing(false);
        setIsSpeaking(false);
        socketRef.current = null;
        reconnectTimeout = setTimeout(connect, 3000);
      };

      socket.onerror = (ev) => {
        console.error('WebSocket error:', ev);
        if (isMounted) {
          setIsConnecting(false);
          setIsProcessing(false);
          setIsSpeaking(false);
        }
      };

      socket.onmessage = (event) => {
        if (!isMounted) return;

        if (event.data instanceof ArrayBuffer) {
          // Binary frame = TTS audio ready to play
          setIsProcessing(false);
          playAudio(event.data);

        } else if (typeof event.data === 'string') {
          const msg = event.data as string;



          if (msg.startsWith('TRANSCRIPT:')) {
            // Completed transcription of user speech (from Whisper or Realtime API)
            const text = msg.slice('TRANSCRIPT:'.length).trim();
            setMessages((prev) => [...prev, { role: 'user', text }]);

          } else if (msg.startsWith('TRANSCRIPT_DELTA:')) {
            // Streaming transcript delta from Realtime API — ignored here,
            // full transcript arrives via TRANSCRIPT: when complete.

          } else if (msg.startsWith('RESPONSE:')) {
            // Legacy server_local text response
            const text = msg.slice('RESPONSE:'.length).trim();
            setMessages((prev) => [...prev, { role: 'assistant', text }]);

          } else if (msg.startsWith('AGENT_RESPONSE:')) {
            // Ballerina agent invocation result (Realtime server invoke_agent tool)
            const text = msg.slice('AGENT_RESPONSE:'.length).trim();
            setMessages((prev) => [...prev, { role: 'assistant', text }]);

          } else if (msg.startsWith('ERROR:')) {
            console.error('Server error:', msg);
            setIsProcessing(false);
            setIsSpeaking(false);

          } else {
            console.warn('Unknown server message:', msg);
            setIsProcessing(false);
          }
        }
      };
    };

    connect();

    return () => {
      isMounted = false;
      if (reconnectTimeout) clearTimeout(reconnectTimeout);
      if (socket) {
        socket.onclose = null;
        socket.close();
      }
      if (pendingBlobUrlRef.current) {
        URL.revokeObjectURL(pendingBlobUrlRef.current);
        pendingBlobUrlRef.current = null;
      }
    };
  }, [url]);

  const playAudio = (data: ArrayBuffer) => {
    if (pendingBlobUrlRef.current) {
      URL.revokeObjectURL(pendingBlobUrlRef.current);
    }

    // Server sends WAV-wrapped PCM16 audio from the Realtime API
    const blob = new Blob([data], { type: 'audio/wav' });
    const audioUrl = URL.createObjectURL(blob);
    pendingBlobUrlRef.current = audioUrl;

    if (!audioPlayerRef.current) {
      audioPlayerRef.current = new Audio();
    }

    const audio = audioPlayerRef.current;
    audio.onplay = () => setIsSpeaking(true);
    audio.onended = () => {
      setIsSpeaking(false);
      URL.revokeObjectURL(audioUrl);
      if (pendingBlobUrlRef.current === audioUrl) {
        pendingBlobUrlRef.current = null;
      }
    };
    audio.onerror = () => setIsSpeaking(false);

    audio.src = audioUrl;
    audio.play().catch((err) => {
      console.error('Audio playback failed:', err);
      setIsSpeaking(false);
    });
  };

  // Stream a single PCM-16 chunk to the server during recording
  const streamChunk = useCallback((pcm16: ArrayBuffer): void => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(pcm16);
    }
  }, []);

  // Signal end of streaming speech — sends trace_marker + stream_end
  const endStream = useCallback((): boolean => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      setIsProcessing(true);

      setIsProcessing(true);

      socketRef.current.send(JSON.stringify({ type: 'stream_end' }));
      return true;
    }
    console.warn(
      'WebSocket not open — stream_end dropped. readyState:',
      socketRef.current?.readyState ?? 'no socket'
    );
    return false;
  }, []);

  // Legacy: send a complete WAV in one shot (non-streaming fallback)
  const sendMessage = useCallback((data: ArrayBuffer): boolean => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      setIsProcessing(true);

      setIsProcessing(true);
      socketRef.current.send(data);
      return true;
    }
    console.warn(
      'WebSocket not open — audio dropped. readyState:',
      socketRef.current?.readyState ?? 'no socket'
    );
    return false;
  }, []);

  return { isConnected, isConnecting, isProcessing, isSpeaking, messages, sendMessage, streamChunk, endStream };
}
