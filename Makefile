.PHONY: c b1 b2 k w


c:
	cd client && npm run dev

c2:
	cd client_2 && npm run dev

b1:
	cd server_OpenAI && bal run

b2:
	cd server_local && bal run

k:
	cd models/kokoro-0.9.4-TTS && env1\Scripts\activate && py kokoro-TTS.py

b3:
	cd server_livekit && .venv\Scripts\activate && py main.py

b33:
	cd server_livekit && .venv\Scripts\activate && py api.py

w:
	cd models/whisper-STT && .venv\Scripts\activate && py whisper-STT.py
