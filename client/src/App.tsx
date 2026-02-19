import { useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { Mic, MicOff, RefreshCw, Radio } from 'lucide-react';
import { useAudio } from './hooks/useAudio';
import { useWebSocket } from './hooks/useWebSocket';
import './App.css';

function App() {
  const { isConnected, isProcessing, sendMessage } = useWebSocket('ws://localhost:8001/ws');
  const { isRecording, volume, startRecording, stopRecording } = useAudio({
    onSilence: (data) => sendMessage(data),
    silenceThreshold: 4000,
  });

  const toggleRecording = () => {
    if (isRecording) {
      stopRecording();
    } else {
      startRecording();
    }
  };

  return (
    <div className="app-container">
      <header className="app-header">
        <motion.div 
          initial={{ opacity: 0, y: -20 }}
          animate={{ opacity: 1, y: 0 }}
          className="logo-section"
        >
          <h1>Ballerina</h1>
          <span className="subtitle">Voice Assistant</span>
        </motion.div>
        
        <div className={`status-badge ${isConnected ? 'connected' : 'disconnected'}`}>
          <Radio size={14} />
          {isConnected ? 'LIVE' : 'OFFLINE'}
        </div>
      </header>

      <main className="assistant-main">
        <div className="visualizer-container">
          <AnimatePresence>
            {isProcessing && (
              <motion.div
                initial={{ scale: 0.8, opacity: 0 }}
                animate={{ scale: 1.2, opacity: 0.2 }}
                exit={{ scale: 0.8, opacity: 0 }}
                transition={{ repeat: Infinity, duration: 1.5, ease: "easeInOut" }}
                className="processing-ring"
              />
            )}
          </AnimatePresence>

          <motion.div 
            className="orb-container"
            animate={{
              scale: isRecording ? 1 + volume * 2 : 1,
              boxShadow: isRecording 
                ? `0 0 ${20 + volume * 100}px rgba(142, 197, 252, 0.6)`
                : '0 0 20px rgba(224, 195, 252, 0.3)'
            }}
          >
            <div className="orb-inner" />
            <div className="orb-glow" />
            
            {/* Ambient particles */}
            {[...Array(3)].map((_, i) => (
              <motion.div
                key={i}
                className="particle"
                animate={{
                  rotate: 360,
                  scale: [1, 1.2, 1],
                }}
                transition={{
                  duration: 10 + i * 2,
                  repeat: Infinity,
                  ease: "linear"
                }}
              />
            ))}
          </motion.div>
        </div>

        <div className="controls-section">
          <div className="transcript-hint">
            {isRecording ? (
              <motion.p 
                animate={{ opacity: [0.5, 1, 0.5] }}
                transition={{ duration: 2, repeat: Infinity }}
              >
                Listening...
              </motion.p>
            ) : (
              <p>Press the microphone to start talking</p>
            )}
          </div>

          <motion.button
            whileHover={{ scale: 1.05 }}
            whileTap={{ scale: 0.95 }}
            onClick={toggleRecording}
            className={`mic-button ${isRecording ? 'active' : ''}`}
          >
            {isRecording ? <Mic size={32} /> : <MicOff size={32} />}
          </motion.button>

          {isProcessing && (
            <motion.div 
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              className="processing-indicator"
            >
              <RefreshCw className="spin" size={16} />
              <span>Ballerina is thinking...</span>
            </motion.div>
          )}
        </div>
      </main>

      <footer className="app-footer">
        <p>Built for the future of voice interactions</p>
      </footer>
    </div>
  );
}

export default App;
