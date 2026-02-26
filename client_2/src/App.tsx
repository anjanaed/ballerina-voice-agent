import { useState, useCallback, useMemo, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Mic, MicOff, Radio, Loader2 } from 'lucide-react';
import {
  LiveKitRoom,
  RoomAudioRenderer,
  useConnectionState,
  useLocalParticipant,
  useRemoteParticipants,
  useRoomContext,
} from '@livekit/components-react';
import { ConnectionState, ParticipantEvent, RoomEvent } from 'livekit-client';
import './App.css';

const WAVE_DURATIONS = Array.from({ length: 12 }, () => 0.5 + Math.random() * 0.55);

function AssistantUI({ 
  connectAgent, 
  onDisconnect,
  isFetching, 
  error 
}: { 
  connectAgent: () => void; 
  onDisconnect: () => void;
  isFetching: boolean; 
  error: string | null;
}) {
  const connectionState = useConnectionState();
  const room = useRoomContext();
  const isConnected = connectionState === ConnectionState.Connected;
  const isConnecting = connectionState === ConnectionState.Connecting || isFetching;

  const { localParticipant, isMicrophoneEnabled } = useLocalParticipant();
  const remoteParticipants = useRemoteParticipants();
  const assistantParticipant = remoteParticipants.length > 0 ? remoteParticipants[0] : null;

  // Debug logging
  useEffect(() => {
    console.log('[Frontend] Connection state:', connectionState);
  }, [connectionState]);

  useEffect(() => {
    console.log('[Frontend] Microphone enabled:', isMicrophoneEnabled);
  }, [isMicrophoneEnabled]);

  useEffect(() => {
    console.log('[Frontend] Remote participants:', remoteParticipants.length);
    remoteParticipants.forEach((p, i) => {
      console.log(`[Frontend] Participant ${i}:`, p.identity, 'Tracks:', p.trackPublications.size);
    });
  }, [remoteParticipants]);

  // Debug: Monitor local track publications
  useEffect(() => {
    if (!localParticipant) return;
    
    console.log('[Frontend] Local participant tracks:', {
      audioTracks: Array.from(localParticipant.audioTrackPublications.values()).map(pub => ({
        sid: pub.trackSid,
        name: pub.trackName,
        muted: pub.isMuted,
        enabled: pub.track?.mediaStreamTrack?.enabled,
        readyState: pub.track?.mediaStreamTrack?.readyState
      })),
      totalPublications: localParticipant.trackPublications.size
    });
  }, [localParticipant, isMicrophoneEnabled]);

  const [assistantIsSpeaking, setAssistantIsSpeaking] = useState(false);
  const [localIsSpeaking, setLocalIsSpeaking] = useState(false);
  const [messages, setMessages] = useState<Array<{ role: 'user' | 'assistant'; text: string }>>([]);
  const conversationEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to latest message
  useEffect(() => {
    conversationEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  useEffect(() => {
    const onData = (payload: Uint8Array, _participant?: any, _kind?: any, topic?: string) => {
      try {
        const raw = new TextDecoder().decode(payload);
        const data = JSON.parse(raw) as { type?: string; text?: string };

        const supportedType = data?.type === 'stt' || data?.type === 'assistant';
        const fromKnownTopic = topic === 'voice-text' || topic === undefined || topic === '';
        const text = data.text;
        if (!supportedType || !fromKnownTopic || !text) {
          return;
        }

        if (data.type === 'stt') {
          setMessages((prev) => [...prev, { role: 'user', text }]);
          setMode('processing');
          return;
        }

        setMessages((prev) => [...prev, { role: 'assistant', text }]);
      } catch (err) {
        console.error('[Frontend] Failed to parse data message', err);
      }
    };

    room.on(RoomEvent.DataReceived, onData);
    return () => {
      room.off(RoomEvent.DataReceived, onData);
    };
  }, [room]);

  useEffect(() => {
    if (!isConnected) {
      setMessages([]);
    }
  }, [isConnected]);

  useEffect(() => {
    if (!assistantParticipant) {
      setAssistantIsSpeaking(false);
      return;
    }
    const onSpeaking = (speaking: boolean) => setAssistantIsSpeaking(speaking);
    assistantParticipant.on(ParticipantEvent.IsSpeakingChanged, onSpeaking);
    setAssistantIsSpeaking(assistantParticipant.isSpeaking);
    return () => { assistantParticipant.off(ParticipantEvent.IsSpeakingChanged, onSpeaking); };
  }, [assistantParticipant]);

  useEffect(() => {
    if (!localParticipant) {
      setLocalIsSpeaking(false);
      return;
    }
    const onSpeaking = (speaking: boolean) => setLocalIsSpeaking(speaking);
    localParticipant.on(ParticipantEvent.IsSpeakingChanged, onSpeaking);
    setLocalIsSpeaking(localParticipant.isSpeaking);
    return () => { localParticipant.off(ParticipantEvent.IsSpeakingChanged, onSpeaking); };
  }, [localParticipant]);

  const [mode, setMode] = useState<'idle' | 'recording' | 'processing' | 'speaking'>('idle');
  useEffect(() => {
    if (assistantIsSpeaking) {
      setMode('speaking');
    } else if (isMicrophoneEnabled && localIsSpeaking) {
      setMode('recording');
    } else if (isMicrophoneEnabled) {
      setMode('recording'); // Default to listening when mic is active
    } else if (isConnected && mode === 'recording') {
      // If mic was just disabled while we were recording, it means we sent audio and are waiting for a response
      setMode('processing');
    } else if (!isConnected && !isConnecting) {
      setMode('idle');
    }
    // Note: if it is ALREADY processing, we leave it processing until assistant speaks or user disconnects
  }, [assistantIsSpeaking, localIsSpeaking, isMicrophoneEnabled, isConnected, isConnecting, mode]);

  const toggleRecording = useCallback(() => {
    console.log('[Frontend] Toggling microphone. Current state:', isMicrophoneEnabled);
    if (isMicrophoneEnabled) {
      localParticipant?.setMicrophoneEnabled(false);
    } else {
      localParticipant?.setMicrophoneEnabled(true);
    }
  }, [isMicrophoneEnabled, localParticipant]);

  const statusLabel = useMemo(() => {
    if (!isConnected && !isConnecting) return 'Press Connect to join the room';
    if (isConnecting) return 'Connecting...';
    if (isConnected && !isMicrophoneEnabled) return 'Click microphone to start talking';
    
    return {
      idle:       'Ready',
      recording:  'Listening…',
      processing: 'Thinking…',
      speaking:   'Speaking…',
    }[mode];
  }, [mode, isConnected, isConnecting, isMicrophoneEnabled]);

  const isProcessing = mode === 'processing' && isConnected;

  return (
    <div className="app-container">
      <header className="app-header">
        <motion.div initial={{ opacity: 0, y: -20 }} animate={{ opacity: 1, y: 0 }} className="logo-section">
          <h1>Voice AI</h1>
          <span className="subtitle">LiveKit WebRTC</span>
        </motion.div>
        
        <div className="header-controls">
          <div className={`status-badge ${isConnected ? 'connected' : isConnecting ? 'connecting' : 'disconnected'}`}>
            {isConnecting ? <Loader2 size={14} className="spinning-loader" /> : <Radio size={14} />}
            {isConnected ? 'LIVE' : isConnecting ? 'CONNECTING...' : 'OFFLINE'}
          </div>
          
          {!isConnected && !isConnecting ? (
            <button 
                onClick={connectAgent} 
                style={{ background: 'var(--color-processing)', border: 'none', color: 'white', borderRadius: '12px', padding: '6px 16px', fontSize: '12px', fontWeight: 'bold', cursor: 'pointer', boxShadow: '0 2px 10px rgba(167, 139, 250, 0.4)' }}
            >
              Connect
            </button>
          ) : (
            <button 
                onClick={onDisconnect} 
                style={{ background: 'transparent', border: '1px solid var(--glass-border)', color: 'white', borderRadius: '12px', padding: '6px 12px', fontSize: '12px', cursor: 'pointer' }}
            >
              Disconnect
            </button>
          )}
        </div>
      </header>

      <main className="assistant-main">
        {error && (
          <div className="error-message" style={{ width: '100%', maxWidth: '800px', marginBottom: '10px', padding: '10px', background: 'rgba(239,68,68,0.1)', border: '1px solid #ef4444', color: '#fca5a5', borderRadius: '8px', zIndex: 10 }}>
            {error}
          </div>
        )}

        <div className="conversation-panel">
          {messages.length === 0 && !isProcessing && (
            <div className="conversation-empty" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', flex: 1, color: 'rgba(255,255,255,0.15)', fontSize: '0.9rem', letterSpacing: '0.5px' }}>
              {isConnected ? 'Start speaking to see the conversation here…' : 'Connect to begin your conversation'}
            </div>
          )}
          <AnimatePresence initial={false}>
            {messages.map((msg: any, i: number) => (
              <motion.div
                key={i}
                className={`bubble ${msg.role === 'user' ? 'bubble-user' : 'bubble-assistant'}`}
                initial={{ opacity: 0, y: 12, scale: 0.96 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                transition={{ duration: 0.22, ease: 'easeOut' }}
              >
                <span className="bubble-label">
                  {msg.role === 'user' ? 'You' : 'Assistant'}
                </span>
                <p>{msg.text}</p>
              </motion.div>
            ))}
          </AnimatePresence>

          <AnimatePresence>
            {isProcessing && (
              <motion.div
                className="bubble bubble-assistant typing-indicator"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.18 }}
              >
                <span className="bubble-label">Assistant</span>
                <div className="typing-dots">
                  {[0, 1, 2].map((i) => (
                    <motion.span
                      key={i}
                      className="typing-dot"
                      animate={{ y: [0, -5, 0] }}
                      transition={{ duration: 0.6, repeat: Infinity, delay: i * 0.15 }}
                    />
                  ))}
                </div>
              </motion.div>
            )}
          </AnimatePresence>

          <div ref={conversationEndRef} />
        </div>



        <div className="footer-controls">
          <div className="status-section">
            {(mode === 'recording' || mode === 'speaking') && (
              <div className="inline-waves">
                {WAVE_DURATIONS.slice(0, 6).map((dur, i) => (
                  <motion.div
                    key={i}
                    className={`wave-bar-tiny ${mode}`}
                    animate={{ height: [8, 24, 8] }}
                    transition={{ duration: dur, repeat: Infinity, delay: i * 0.1 }}
                  />
                ))}
              </div>
            )}
            <div className="status-hint">
              <AnimatePresence mode="wait">
                <motion.p 
                  key={statusLabel as string} 
                  initial={{ opacity: 0, x: -10 }} 
                  animate={{ opacity: 1, x: 0 }} 
                  exit={{ opacity: 0, x: 10 }} 
                  className={`mode-label mode-${mode}`}
                >
                  {statusLabel as string}
                </motion.p>
              </AnimatePresence>
            </div>
          </div>

          <motion.button
            whileHover={!assistantIsSpeaking && isConnected ? { scale: 1.05 } : {}}
            whileTap={!assistantIsSpeaking && isConnected ? { scale: 0.95 } : {}}
            onClick={toggleRecording}
            disabled={!isConnected || assistantIsSpeaking}
            className={`mic-button ${isMicrophoneEnabled ? 'active' : ''} ${!isConnected || assistantIsSpeaking ? 'disabled' : ''}`}
          >
            {isMicrophoneEnabled ? <Mic size={24} /> : <MicOff size={24} />}
          </motion.button>
        </div>

        <AnimatePresence>
          {!isConnected && !isConnecting && !error && (
            <div className="offline-warning">
              Server Disconnected
            </div>
          )}
        </AnimatePresence>
      </main>
      
      {/* Required for LiveKit Audio */}
      <RoomAudioRenderer />
    </div>
  );
}

function App() {
  const [connectionDetails, setConnectionDetails] = useState<{ url: string; token: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isFetching, setIsFetching] = useState(false);

  const connect = useCallback(async () => {
    if (connectionDetails) return;
    try {
      setIsFetching(true);
      setError(null);
      console.log('[Frontend] Fetching token from http://localhost:8002/getToken...');
      const response = await fetch('http://localhost:8002/getToken?roomName=voice-room&participantName=user');
      if (!response.ok) {
        throw new Error('Failed to fetch token from backend');
      }
      const data = await response.json();
      console.log('[Frontend] Token received! URL:', data.url);
      setConnectionDetails(data);
    } catch (err: any) {
      console.error('[Frontend] Token fetch error:', err.message);
      setError(err.message);
    } finally {
      setIsFetching(false);
    }
  }, [connectionDetails]);

  const disconnect = useCallback(() => {
    setConnectionDetails(null);
  }, []);

  return (
    <LiveKitRoom
      token={connectionDetails?.token}
      serverUrl={connectionDetails?.url}
      connect={!!connectionDetails}
      audio={true}
      onDisconnected={disconnect}
    >
      <AssistantUI connectAgent={connect} onDisconnect={disconnect} isFetching={isFetching} error={error} />
    </LiveKitRoom>
  );
}

export default App;
