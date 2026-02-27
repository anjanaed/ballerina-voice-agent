import asyncio
import os
import io
import wave
import json
from dotenv import load_dotenv

from livekit import rtc
from websockets.asyncio.client import connect as ws_connect

load_dotenv()

# Audio settings
SAMPLE_RATE = 16000
NUM_CHANNELS = 1

BALLERINA_WS_URL = "ws://localhost:8002/ws"
TTS_FRAME_MS = 20

def create_wav_buffer(pcm_data: bytes, sample_rate: int) -> io.BytesIO:
    wav_io = io.BytesIO()
    with wave.open(wav_io, 'wb') as wav_file:
        wav_file.setnchannels(NUM_CHANNELS)
        wav_file.setsampwidth(2) # 16 bits
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm_data)
    wav_io.seek(0)
    wav_io.name = "audio.wav"
    return wav_io

audio_source: rtc.AudioSource | None = None
tts_track_published = False
tts_lock = asyncio.Lock()


async def ensure_tts_track_published(room: rtc.Room):
    global tts_track_published, audio_source
    if tts_track_published:
        return
    if audio_source is None:
        raise RuntimeError("Audio source not initialized")

    print("Publishing TTS audio track...")
    track = rtc.LocalAudioTrack.create_audio_track("assistant-voice", audio_source)
    options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    await room.local_participant.publish_track(track, options)
    tts_track_published = True
    print("TTS track published")


async def publish_text_event(room: rtc.Room, message_type: str, text: str):
    payload = json.dumps({"type": message_type, "text": text}).encode('utf-8')
    print(f"[Backend] Publishing data event: type={message_type}, text='{text}', payload_size={len(payload)} bytes")
    await room.local_participant.publish_data(payload, reliable=True, topic="voice-text")
    print(f"[Backend] Data published successfully")

def request_audio_subscriptions(room: rtc.Room):
    for identity, participant in room.remote_participants.items():
        for publication in participant.track_publications.values():
            if publication.kind != rtc.TrackKind.KIND_AUDIO:
                continue
            if not publication.subscribed:
                publication.set_subscribed(True)
                print(
                    f"[Backend] Subscription re-requested: participant={identity} sid={publication.sid}",
                    flush=True,
                )


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


async def process_speech(audio_data: bytes, room: rtc.Room):
    """Send audio to Ballerina over WebSocket and handle the STT/LLM/TTS pipeline."""
    print("Processing speech chunk...")
    wav_bytes = create_wav_buffer(audio_data, SAMPLE_RATE).read()

    try:
        async with ws_connect(BALLERINA_WS_URL, max_size=10 * 1024 * 1024) as ws:
            await ws.send(wav_bytes)
            print("Sent audio to Ballerina, waiting for response...")

            tts_wav: bytes | None = None

            async for msg in ws:
                if isinstance(msg, bytes):
                    tts_wav = msg
                    print(f"Received TTS audio: {len(tts_wav)} bytes")

                elif isinstance(msg, str):
                    if msg.startswith("TRANSCRIPT:"):
                        text = msg[len("TRANSCRIPT:"):]
                        print(f"STT Output: {text}")
                        await publish_text_event(room, "stt", text)

                    elif msg.startswith("RESPONSE:"):
                        llm_text = msg[len("RESPONSE:"):]
                        print(f"LLM Output: {llm_text}")
                        await publish_text_event(room, "assistant", llm_text)
                        break

                    elif msg.startswith("ERROR:"):
                        print(f"Ballerina error: {msg}")
                        return

        if tts_wav:
            await ensure_tts_track_published(room)
            print("Streaming TTS to Room...")
            await stream_wav_to_livekit(tts_wav)
            print("Done streaming TTS.")

    except Exception as e:
        print(f"Error in pipeline: {e}")
        import traceback
        traceback.print_exc()

async def handle_audio_stream(track: rtc.Track, room: rtc.Room):
    audio_stream = rtc.AudioStream(track)
    buffer = bytearray()
    min_chunk_seconds = 0.5
    was_muted = track.muted
    
    print("Started listening to audio stream...")
    
    async for event in audio_stream:
        audio_frame = event.frame
            
        global SAMPLE_RATE
        SAMPLE_RATE = audio_frame.sample_rate

        is_muted = track.muted

        if was_muted and not is_muted:
            print("Track unmuted, starting new capture segment...")
            buffer.clear()

        if not is_muted:
            pcm_data = bytes(audio_frame.data)
            buffer.extend(pcm_data)

        if not was_muted and is_muted:
            buffered_seconds = len(buffer) / (2 * NUM_CHANNELS * SAMPLE_RATE)
            if buffered_seconds >= min_chunk_seconds:
                print("Track muted, sending captured segment to pipeline...")
                audio_to_process = bytes(buffer)
                asyncio.create_task(process_speech(audio_to_process, room))
            else:
                print("[Backend] Segment too short, skipping STT")
            buffer.clear()

        was_muted = is_muted

    if len(buffer) > 0:
        buffered_seconds = len(buffer) / (2 * NUM_CHANNELS * SAMPLE_RATE)
        if not track.muted and buffered_seconds >= min_chunk_seconds:
            print("[Backend] Stream ended, flushing remaining buffered audio...")
            asyncio.create_task(process_speech(bytes(buffer), room))


def register_room_handlers(room: rtc.Room):
    @room.on("track_subscribed")
    def on_track_subscribed(track: rtc.Track, publication: rtc.RemoteTrackPublication, participant: rtc.RemoteParticipant):
        print(f"[Backend] Track subscribed: {participant.identity} - {track.kind}")
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            asyncio.create_task(handle_audio_stream(track, room))

    @room.on("participant_connected")
    def on_participant_connected(participant: rtc.RemoteParticipant):
        print(f"[Backend] Participant connected: {participant.identity}")
        request_audio_subscriptions(room)

    @room.on("participant_disconnected")
    def on_participant_disconnected(participant: rtc.RemoteParticipant):
        print(f"[Backend] Participant disconnected: {participant.identity}")

    @room.on("track_published")
    def on_track_published(publication: rtc.RemoteTrackPublication, participant: rtc.RemoteParticipant):
        if publication.kind == rtc.TrackKind.KIND_AUDIO:
            print(f"[Backend] Audio track published by '{participant.identity}' (subscribed={publication.subscribed}, muted={publication.muted})")
            publication.set_subscribed(True)
            print(f"[Backend] Subscription requested on track_published sid={publication.sid}")

    @room.on("track_subscription_failed")
    def on_track_subscription_failed(participant: rtc.RemoteParticipant, track_sid: str, error: str):
        print(f"[Backend] Track subscription failed: participant={participant.identity}, sid={track_sid}, error={error}")

    @room.on("track_muted")
    def on_track_muted(participant: rtc.Participant, publication: rtc.TrackPublication):
        print(f"[Backend] Track muted: participant={participant.identity}, sid={publication.sid}")

    @room.on("track_unmuted")
    def on_track_unmuted(participant: rtc.Participant, publication: rtc.TrackPublication):
        print(f"[Backend] Track unmuted: participant={participant.identity}, sid={publication.sid}")

    @room.on("connection_state_changed")
    def on_connection_state_changed(state: rtc.ConnectionState):
        print(f"[Backend] Connection state changed: {state}")
        if state == rtc.ConnectionState.CONN_CONNECTED:
            request_audio_subscriptions(room)

async def main():
    global audio_source
    url = os.getenv("LIVEKIT_URL")
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")

    room = rtc.Room(loop=asyncio.get_running_loop())
    audio_source = rtc.AudioSource(24000, 1) # OpenAI TTS max freq is 24kHz
    register_room_handlers(room)

    print(f"[Backend] Initializing agent...")
    print(f"[Backend] LiveKit URL: {url}")

    # Generate token for the agent
    from livekit import api
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
    
    print(f"[Backend] Token generated with subscribe permissions", flush=True)

    print(f"[Backend] Connecting to room at {url}...")
    
    try:
        # Use default auto-subscribe behavior
        await room.connect(url, token)
        print(f"[Backend] Connected to room: {room.name}", flush=True)
        await ensure_tts_track_published(room)
        
        # Wait a moment for room state to sync
        await asyncio.sleep(1)
        
        # Check for participants
        print(f"[Backend] Checking for participants... Found: {len(room.remote_participants)}", flush=True)
        
        # Subscribe to all existing participants' tracks
        for identity, participant in room.remote_participants.items():
            print(f"[Backend] Found participant: {identity} with {len(participant.track_publications)} tracks", flush=True)
            for publication in participant.track_publications.values():
                if publication.kind == rtc.TrackKind.KIND_AUDIO:
                    print(
                        f"[Backend] Existing audio publication: sid={publication.sid}, "
                        f"subscribed={publication.subscribed}, muted={publication.muted}",
                        flush=True,
                    )
                    if not publication.subscribed:
                        publication.set_subscribed(True)
                        print(
                            f"[Backend] Subscription requested for existing track sid={publication.sid}",
                            flush=True,
                        )
        
        print("[Backend] Ready", flush=True)
    except Exception as e:
        print(f"[Backend] ERROR during connection: {e}", flush=True)
        import traceback
        traceback.print_exc()
        return
    
    try:
        while room.connection_state == rtc.ConnectionState.CONN_CONNECTED:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        print("[Backend] Shutting down...")
    finally:
        await room.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
