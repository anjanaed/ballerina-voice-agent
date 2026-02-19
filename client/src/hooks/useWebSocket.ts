import { useEffect, useRef, useState, useCallback } from 'react';

export function useWebSocket(url: string) {
  const [isConnected, setIsConnected] = useState(false);
  const [isProcessing, setIsProcessing] = useState(false);
  const socketRef = useRef<WebSocket | null>(null);
  const audioPlayerRef = useRef<HTMLAudioElement | null>(null);

  useEffect(() => {
    let socket: WebSocket | null = null;
    let reconnectTimeout: any = null;

    const connect = () => {
      socket = new WebSocket(url);
      socket.binaryType = 'arraybuffer';
      socketRef.current = socket;

      socket.onopen = () => setIsConnected(true);
      socket.onclose = () => {
        setIsConnected(false);
        setIsProcessing(false);
        reconnectTimeout = setTimeout(connect, 3000); // Try to reconnect in 3s
      };
      
      socket.onmessage = async (event) => {
        if (event.data instanceof ArrayBuffer) {
          setIsProcessing(false);
          playAudio(event.data);
        }
      };
    };

    connect();

    return () => {
      if (socket) socket.close();
      if (reconnectTimeout) clearTimeout(reconnectTimeout);
    };
  }, [url]);

  const playAudio = (data: ArrayBuffer) => {
    const blob = new Blob([data], { type: 'audio/mp3' });
    const audioUrl = URL.createObjectURL(blob);
    
    if (audioPlayerRef.current) {
      audioPlayerRef.current.src = audioUrl;
      audioPlayerRef.current.play();
    } else {
      const audio = new Audio(audioUrl);
      audioPlayerRef.current = audio;
      audio.play();
    }
  };

  const sendMessage = useCallback((data: ArrayBuffer) => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      setIsProcessing(true);
      socketRef.current.send(data);
    }
  }, []);

  return { isConnected, isProcessing, sendMessage };
}
