import { useCallback, useMemo, useRef, useEffect } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Mic, MicOff, Radio } from 'lucide-react';
import { useAudio } from './hooks/useAudio';
import { useWebSocket } from './hooks/useWebSocket';
import type { Message } from './hooks/useWebSocket';
import './App.css';

const WAVE_DURATIONS = Array.from({ length: 12 }, () => 0.5 + Math.random() * 0.55);

function App() {
  const { isConnected, isProcessing, isSpeaking, messages, sendMessage } =
    useWebSocket('ws://localhost:8001/ws');

  const handleSilence = useCallback(
    (data: ArrayBuffer) => { sendMessage(data); },
    [sendMessage]
  );

  const { isRecording, volume, silenceSecondsLeft, startRecording, stopRecording } = useAudio({
    onSilence: handleSilence,
    silenceThreshold: 4000,
  });

  const toggleRecording = useCallback(() => {
    if (isRecording) stopRecording(); else startRecording();
  }, [isRecording, startRecording, stopRecording]);

  const mode: 'idle' | 'recording' | 'processing' | 'speaking' = isSpeaking
    ? 'speaking' : isProcessing ? 'processing' : isRecording ? 'recording' : 'idle';

  const statusLabel = useMemo(() => ({
    idle:       'Press the microphone to start talking',
    recording:  silenceSecondsLeft !== null ? `Sending in ${silenceSecondsLeft}s…` : 'Listening…',
    processing: 'Thinking…',
    speaking:   'Speaking…',
  }[mode]), [mode, silenceSecondsLeft]);

  const orbScale = isRecording ? 1 + Math.min(volume * 3, 0.6) : isSpeaking ? 1.08 : 1;

  const conversationEndRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    conversationEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  return (
    <div className="app-container">
      <header className="app-header">
        <motion.div initial={{ opacity: 0, y: -20 }} animate={{ opacity: 1, y: 0 }} className="logo-section">
          <h1>Ballerina</h1>
          <span className="subtitle">Voice Assistant</span>
        </motion.div>
        <div className={`status-badge ${isConnected ? 'connected' : 'disconnected'}`}>
          <Radio size={14} />
          {isConnected ? 'LIVE' : 'OFFLINE'}
        </div>
      </header>

      <main className="assistant-main">
        {/* Conversation history panel */}
        <div className="conversation-panel">
          <AnimatePresence initial={false}>
            {messages.map((msg: Message, i: number) => (
              <motion.div
                key={i}
                className={`bubble ${msg.role === 'user' ? 'bubble-user' : 'bubble-assistant'}`}
                initial={{ opacity: 0, y: 12, scale: 0.96 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                transition={{ duration: 0.22, ease: 'easeOut' }}
              >
                <span className="bubble-label">
                  {msg.role === 'user' ? 'You' : 'Ballerina'}
                </span>
                <p>{msg.text}</p>
              </motion.div>
            ))}
          </AnimatePresence>

          {/* Typing indicator while server is processing */}
          <AnimatePresence>
            {isProcessing && (
              <motion.div
                className="bubble bubble-assistant typing-indicator"
                initial={{ opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 0.18 }}
              >
                <span className="bubble-label">Ballerina</span>
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

        {/* Visualizer orb and rings */}
        <div className="visualizer-container">
          <AnimatePresence>
            {(isRecording || isSpeaking) && [0, 1, 2].map((i) => (
              <motion.div
                key={`ring-${mode}-${i}`}
                className={`ripple-ring ${isSpeaking ? 'ring-speaking' : 'ring-recording'}`}
                initial={{ scale: 0.9, opacity: 0.55 }}
                animate={{ scale: 1.9 + i * 0.28, opacity: 0 }}
                transition={{ duration: isSpeaking ? 1.1 : 1.7, repeat: Infinity, delay: i * (isSpeaking ? 0.28 : 0.45), ease: 'easeOut' }}
              />
            ))}
          </AnimatePresence>

          <AnimatePresence>
            {isProcessing && (
              <motion.div
                key="processing-ring"
                className="processing-ring"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1, rotate: 360 }}
                exit={{ opacity: 0 }}
                transition={{ duration: 1.6, repeat: Infinity, ease: 'linear' }}
              />
            )}
          </AnimatePresence>

          <motion.div className="orb-container" animate={{ scale: orbScale }} transition={{ type: 'spring', stiffness: 250, damping: 18 }}>
            <div className={`orb-inner orb-${mode}`} />
            <div className={`orb-glow orb-glow-${mode}`} />
          </motion.div>
        </div>

        {/* Wave bars shown while speaking */}
        <AnimatePresence>
          {isSpeaking && (
            <motion.div className="wave-bars" initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 12 }} transition={{ duration: 0.22 }}>
              {WAVE_DURATIONS.map((dur, i) => (
                <motion.div key={i} className="wave-bar" animate={{ scaleY: [0.2, 1, 0.2] }} transition={{ duration: dur, repeat: Infinity, delay: i * 0.055, ease: 'easeInOut' }} />
              ))}
            </motion.div>
          )}
        </AnimatePresence>

        {/* Controls and status displays */}
        <div className="controls-section">
          <div className="status-hint">
            <AnimatePresence mode="wait">
              <motion.p key={statusLabel} initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -4 }} transition={{ duration: 0.16 }} className={`mode-label mode-${mode}`}>
                {statusLabel}
              </motion.p>
            </AnimatePresence>
          </div>

          <motion.button
            whileHover={!isProcessing && !isSpeaking ? { scale: 1.07 } : {}}
            whileTap={!isProcessing && !isSpeaking ? { scale: 0.93 } : {}}
            onClick={toggleRecording}
            disabled={isProcessing || isSpeaking}
            className={`mic-button ${isRecording ? 'active' : ''} ${isProcessing || isSpeaking ? 'disabled' : ''}`}
            aria-label={isRecording ? 'Stop recording' : 'Start recording'}
          >
            {isRecording ? <Mic size={32} /> : <MicOff size={32} />}
          </motion.button>

          <AnimatePresence>
            {!isConnected && (
              <motion.p className="offline-warning" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
                Reconnecting to server…
              </motion.p>
            )}
          </AnimatePresence>
        </div>
      </main>

      <footer className="app-footer">
        <p>Built for the future of voice interactions</p>
      </footer>
    </div>
  );
}

export default App;
