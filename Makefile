.PHONY: c b1 b2 k w


c:
	cd client && npm run dev

b1:
	cd server-OpenAI && bal run

b2:
	cd server-local && bal run

k:
	cd models/kokoro-0.9.4-TTS && env1\Scripts\activate && py kokoro-TTS.py

w:
	cd models/whisper-STT && .venv\Scripts\activate && py whisper-STT.py
