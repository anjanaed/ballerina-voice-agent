import { useCallback, useMemo, useRef, useEffect, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Mic, MicOff, Radio, ChevronDown, Loader2 } from 'lucide-react';
import { useAudio } from './hooks/useAudio';
import { useWebSocket } from './hooks/useWebSocket';
import type { Message } from './hooks/useWebSocket';
import './App.css';

const WAVE_DURATIONS = Array.from({ length: 12 }, () => 0.5 + Math.random() * 0.55);

function App() {
  const [selectedPort, setSelectedPort] = useState('8002');

  const { isConnected, isConnecting, isProcessing, isSpeaking, messages, sendMessage } =
    useWebSocket(`ws://localhost:${selectedPort}/ws`);

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

  const [isDropdownOpen, setIsDropdownOpen] = useState(false);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsDropdownOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const ports = [
    { id: '8001', label: 'OpenAI'},
    { id: '8002', label: 'Open Source'},
  ];

  const currentPort = ports.find(p => p.id === selectedPort) || ports[1];

  return (
    <div className="app-container">
      <header className="app-header">
        <motion.div initial={{ opacity: 0, y: -20 }} animate={{ opacity: 1, y: 0 }} className="logo-section">
          <h1>Ballerina</h1>
          <span className="subtitle">Voice Assistant</span>
        </motion.div>
        
        <div className="header-controls">
          <div className="custom-dropdown" ref={dropdownRef}>
            <motion.button
              whileHover={!isConnecting ? { backgroundColor: 'rgba(255,255,255,0.1)' } : {}}
              whileTap={!isConnecting ? { scale: 0.98 } : {}}
              onClick={() => !isConnecting && setIsDropdownOpen(!isDropdownOpen)}
              className={`dropdown-trigger ${isConnecting ? 'connecting' : ''} ${isDropdownOpen ? 'active' : ''}`}
            >
              {isConnecting ? (
                <Loader2 size={16} className="spinning-loader" />
              ) : (
                <span className="port-icon">{currentPort.icon}</span>
              )}
              <span className="selected-label">{isConnecting ? 'Connecting…' : currentPort.label}</span>
              <ChevronDown size={14} className={`chevron ${isDropdownOpen ? 'rotate' : ''}`} />
            </motion.button>

            <AnimatePresence>
              {isDropdownOpen && (
                <motion.div
                  initial={{ opacity: 0, y: 10, scale: 0.95 }}
                  animate={{ opacity: 1, y: 0, scale: 1 }}
                  exit={{ opacity: 0, y: 10, scale: 0.95 }}
                  transition={{ duration: 0.2, ease: [0.23, 1, 0.32, 1] }}
                  className="dropdown-menu"
                >
                  {ports.map((port) => (
                    <motion.button
                      key={port.id}
                      whileHover={{ backgroundColor: 'rgba(255,255,255,0.08)', x: 4 }}
                      onClick={() => {
                        setSelectedPort(port.id);
                        setIsDropdownOpen(false);
                      }}
                      className={`dropdown-item ${selectedPort === port.id ? 'selected' : ''}`}
                    >
                      <span className="item-icon">{port.icon}</span>
                      <span className="item-label">{port.label}</span>
                      {selectedPort === port.id && <motion.div layoutId="active-indicator" className="active-dot" />}
                    </motion.button>
                  ))}
                </motion.div>
              )}
            </AnimatePresence>
          </div>

          <div className={`status-badge ${isConnected ? 'connected' : 'disconnected'}`}>
            <Radio size={14} />
            {isConnected ? 'LIVE' : 'OFFLINE'}
          </div>
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

        {/* Background Visualizer orb */}
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

        {/* COMPACT HORIZONTAL FOOTER */}
        <div className="footer-controls">
          <div className="status-section">
            {(isRecording || isSpeaking) && (
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
                  key={statusLabel} 
                  initial={{ opacity: 0, x: -10 }} 
                  animate={{ opacity: 1, x: 0 }} 
                  exit={{ opacity: 0, x: 10 }} 
                  className={`mode-label mode-${mode}`}
                >
                  {statusLabel}
                </motion.p>
              </AnimatePresence>
            </div>
          </div>

          <motion.button
            whileHover={!isProcessing && !isSpeaking ? { scale: 1.05 } : {}}
            whileTap={!isProcessing && !isSpeaking ? { scale: 0.95 } : {}}
            onClick={toggleRecording}
            disabled={isProcessing || isSpeaking}
            className={`mic-button ${isRecording ? 'active' : ''} ${isProcessing || isSpeaking ? 'disabled' : ''}`}
          >
            {isRecording ? <Mic size={24} /> : <MicOff size={24} />}
          </motion.button>
        </div>

        <AnimatePresence>
          {!isConnected && (
            <div className="offline-warning">
              Reconnecting to server…
            </div>
          )}
        </AnimatePresence>
      </main>

      <footer className="app-footer">
        <p>Built for the future of voice interactions</p>
      </footer>
    </div>
  );
}

export default App;
