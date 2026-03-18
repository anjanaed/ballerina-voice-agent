import asyncio
import os
import io
import wave
import json
import time
import uuid
from collections import defaultdict, deque
from dotenv import load_dotenv
from livekit import api
from livekit import rtc
from websockets.asyncio.client import connect as ws_connect

load_dotenv()

# Audio settings
SAMPLE_RATE = 16000
NUM_CHANNELS = 1

BALLERINA_WS_URL = os.getenv("BALLERINA_WS_URL", "ws://localhost:8002/ws")
TTS_FRAME_MS = 20

def create_wav_buffer(pcm_data: bytes, sample_rate: int, num_channels: int) -> io.BytesIO:
    wav_io = io.BytesIO()
    with wave.open(wav_io, 'wb') as wav_file:
        wav_file.setnchannels(num_channels)
        wav_file.setsampwidth(2) # 16 bits
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm_data)
    wav_io.seek(0)
    wav_io.name = "audio.wav"
    return wav_io

audio_source: rtc.AudioSource | None = None
tts_track_published = False
tts_lock = asyncio.Lock()
bal_ws: any = None
bal_ws_lock = asyncio.Lock()
bal_pipeline_lock = asyncio.Lock()

async def get_bal_ws():
    """Returns a persistent WebSocket connection to the Ballerina server."""
    global bal_ws
    async with bal_ws_lock:
        if bal_ws is None:
            print(f"Connecting to Ballerina WebSocket at {BALLERINA_WS_URL}...")
            bal_ws = await ws_connect(BALLERINA_WS_URL, max_size=10 * 1024 * 1024)
            print(f"Connected to Ballerina WebSocket!")
        return bal_ws


def now_ms() -> int:
    return int(time.time() * 1000)



async def ensure_tts_track_published(room: rtc.Room):
    global tts_track_published, audio_source
    if tts_track_published:
        return
    if audio_source is None:
        raise RuntimeError("Audio source not initialized")

    track = rtc.LocalAudioTrack.create_audio_track("assistant-voice", audio_source)
    options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    await room.local_participant.publish_track(track, options)
    tts_track_published = True


async def publish_text_event(room: rtc.Room, message_type: str, text: str):
    payload = json.dumps({"type": message_type, "text": text}).encode('utf-8')
    await room.local_participant.publish_data(payload, reliable=True, topic="voice-text")


async def stream_wav_to_livekit(wav_bytes: bytes):
    """Decode a WAV buffer from Kokoro and push PCM frames into the LiveKit AudioSource."""
    global audio_source
    if audio_source is None:
        return

    wav_io = io.BytesIO(wav_bytes)
    with wave.open(wav_io, 'rb') as wf:
        rate = wf.getframerate()
        channels = wf.getnchannels()
        pcm = wf.readframes(wf.getnframes())

    frame_samples = (rate * TTS_FRAME_MS) // 1000
    frame_bytes_size = frame_samples * channels * 2
    pending = bytearray(pcm)

    async with tts_lock:
        while len(pending) >= frame_bytes_size:
            chunk = bytes(pending[:frame_bytes_size])
            del pending[:frame_bytes_size]
            await audio_source.capture_frame(
                rtc.AudioFrame(chunk, rate, channels, frame_samples)
            )
        if pending:
            if len(pending) % 2 != 0:
                pending.append(0)
            spc = len(pending) // (2 * channels)
            if spc > 0:
                await audio_source.capture_frame(
                    rtc.AudioFrame(bytes(pending), rate, channels, spc)
                )


async def process_speech(
    audio_data: bytes,
    room: rtc.Room,
    sample_rate: int = SAMPLE_RATE,
    num_channels: int = NUM_CHANNELS,
):
    """Send audio to Ballerina over WebSocket and handle the STT/LLM/TTS pipeline."""
    wav_bytes = create_wav_buffer(audio_data, sample_rate, num_channels).read()

    try:
        async with bal_pipeline_lock:
            ws = await get_bal_ws()
            await ws.send(wav_bytes)

            tts_wav: bytes | None = None

            while True:
                try:
                    msg = await ws.recv()
                except Exception as e:
                    print(f"WebSocket receive error: {e}")
                    async with bal_ws_lock:
                        global bal_ws
                        bal_ws = None
                    break

                if isinstance(msg, bytes):
                    tts_wav = msg
                    print(f"Received TTS audio: {len(tts_wav)} bytes")

                elif isinstance(msg, str):
                    if msg.startswith("MARK:"):
                        continue

                    if msg.startswith("TRANSCRIPT:"):
                        text = msg[len("TRANSCRIPT:"):]
                        await publish_text_event(room, "stt", text)

                    elif msg.startswith("RESPONSE:"):
                        llm_text = msg[len("RESPONSE:"):]
                        await publish_text_event(room, "assistant", llm_text)
                        break

                    elif msg.startswith("ERROR:"):
                        print(f"Ballerina error: {msg}")
                        return

        if tts_wav:
            await ensure_tts_track_published(room)
            await stream_wav_to_livekit(tts_wav)

    except Exception as e:
        print(f"Error in pipeline: {e}")
        import traceback
        traceback.print_exc()

class AudioProcessor:
    def __init__(self, room: rtc.Room, participant_identity: str):
        self.room = room
        self.participant_identity = participant_identity
        self.buffer = bytearray()
        self.capture_start_ms: int | None = None
        self.min_chunk_seconds = 0.5
        self.sample_rate = SAMPLE_RATE
        self.num_channels = NUM_CHANNELS

    def add_frame(self, frame: rtc.AudioFrame):
        if self.capture_start_ms is None:
            self.capture_start_ms = now_ms()
        frame_rate = getattr(frame, "sample_rate", None)
        frame_channels = getattr(frame, "num_channels", None)
        if isinstance(frame_rate, int) and frame_rate > 0:
            self.sample_rate = frame_rate
        if isinstance(frame_channels, int) and frame_channels > 0:
            self.num_channels = frame_channels
        self.buffer.extend(bytes(frame.data))

    async def flush(self):
        if not self.buffer:
            return
        
        buffered_seconds = len(self.buffer) / (2 * self.num_channels * self.sample_rate)
        
        if buffered_seconds >= self.min_chunk_seconds:
            audio_to_process = bytes(self.buffer)
            asyncio.create_task(
                process_speech(
                    audio_to_process,
                    self.room,
                    sample_rate=self.sample_rate,
                    num_channels=self.num_channels,
                )
            )
        
        self.buffer.clear()
        self.capture_start_ms = None

audio_processors: dict[str, AudioProcessor] = {}

async def handle_audio_stream(track: rtc.Track, room: rtc.Room, participant_identity: str):
    processor = AudioProcessor(room, participant_identity)
    audio_processors[track.sid] = processor
    
    audio_stream = rtc.AudioStream(track)
    async for event in audio_stream:
        if not track.muted:
            processor.add_frame(event.frame)
            
    # Cleanup when stream ends
    if track.sid in audio_processors:
        del audio_processors[track.sid]


def register_room_handlers(room: rtc.Room):
    @room.on("track_subscribed")
    def on_track_subscribed(track: rtc.Track, publication: rtc.RemoteTrackPublication, participant: rtc.RemoteParticipant):
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            asyncio.create_task(handle_audio_stream(track, room, participant.identity))

    @room.on("track_muted")
    def on_track_muted(participant: rtc.RemoteParticipant, publication: rtc.RemoteTrackPublication):
        if publication.sid in audio_processors:
            asyncio.create_task(audio_processors[publication.sid].flush())

    @room.on("track_unmuted")
    def on_track_unmuted(participant: rtc.RemoteParticipant, publication: rtc.RemoteTrackPublication):
        if publication.sid in audio_processors:
            # Clear buffer and start fresh for new utterance
            audio_processors[publication.sid].buffer.clear()
            audio_processors[publication.sid].capture_start_ms = None

    @room.on("data_received")
    def on_data_received(*args):
        pass

    @room.on("track_subscription_failed")
    def on_track_subscription_failed(participant: rtc.RemoteParticipant, track_sid: str, error: str):
        print(f"Track subscription failed: participant={participant.identity}, sid={track_sid}, error={error}")


async def main():
    global audio_source
    url = os.getenv("LIVEKIT_URL")
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")

    room = rtc.Room(loop=asyncio.get_running_loop())
    audio_source = rtc.AudioSource(24000, 1) # OpenAI TTS max freq is 24kHz
    register_room_handlers(room)

    print("Starting LiveKit Python agent...")

    # Generate token for the agent
    token = api.AccessToken(api_key, api_secret) \
        .with_identity("python-agent") \
        .with_name("python-agent") \
        .with_grants(api.VideoGrants(
            room_join=True, 
            room="voice-room",
            can_subscribe=True,
            can_publish=True,
            can_publish_data=True,
        )) \
        .to_jwt()
    
    print(f"Connecting to room at {url}...")
    
    try:
        await room.connect(url, token)
        print(f"Connected to room: {room.name}", flush=True)
        await ensure_tts_track_published(room)
        print("Python agent ready", flush=True)
    except Exception as e:
        print(f"ERROR during connection: {e}", flush=True)
        import traceback
        traceback.print_exc()
        return
    
    try:
        while room.connection_state == rtc.ConnectionState.CONN_CONNECTED:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        print("Shutting down...")
    finally:
        await room.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
