import asyncio
import os
import io
import wave
import json
from dotenv import load_dotenv

from livekit import rtc
import openai

load_dotenv()

openai_client = openai.AsyncOpenAI(api_key=os.environ.get("OPENAI_API_KEY"))

# Audio settings
SAMPLE_RATE = 16000 # for reading
NUM_CHANNELS = 1

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

TTS_SAMPLE_RATE = 24000
TTS_CHANNELS = 1
TTS_FRAME_MS = 20
TTS_SAMPLES_PER_FRAME = (TTS_SAMPLE_RATE * TTS_FRAME_MS) // 1000
TTS_BYTES_PER_FRAME = TTS_SAMPLES_PER_FRAME * TTS_CHANNELS * 2


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


def publish_text_event(room: rtc.Room, message_type: str, text: str):
    payload = json.dumps({"type": message_type, "text": text})
    room.local_participant.publish_data(payload, reliable=True, topic="voice-text")

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

async def log_subscription_state(room: rtc.Room):
    while room.connection_state == rtc.ConnectionState.CONN_CONNECTED:
        for identity, participant in room.remote_participants.items():
            for publication in participant.track_publications.values():
                if publication.kind == rtc.TrackKind.KIND_AUDIO:
                    if not publication.subscribed:
                        publication.set_subscribed(True)
                    print(
                        f"[Backend] SubState participant={identity} sid={publication.sid} "
                        f"subscribed={publication.subscribed} muted={publication.muted} "
                        f"has_track={publication.track is not None}",
                        flush=True,
                    )
        await asyncio.sleep(5)

async def process_speech(audio_data: bytes, room: rtc.Room):
    global audio_source
    print("Processing speech chunk...")
    # 1. STT
    wav_buffer = create_wav_buffer(audio_data, SAMPLE_RATE)
    try:
        print("Sending to STT...")
        transcription = await openai_client.audio.transcriptions.create(
            model="whisper-1", 
            file=wav_buffer
        )
        text = transcription.text.strip()
        # audio_seconds = len(audio_data) / (2 * NUM_CHANNELS * SAMPLE_RATE)
        # print(
        #     f"[Backend][STT_OK] bytes={len(audio_data)} duration={audio_seconds:.2f}s sample_rate={SAMPLE_RATE} text='{text}'",
        #     flush=True,
        # )
        print(f"STT Output: {text}")
        if not text:
            return
        publish_text_event(room, "stt", text)

        # 2. LLM
        print("Sending to LLM...")
        response = await openai_client.chat.completions.create(
            model="gpt-4o",
            messages=[
                {
                    "role": "system",
                    "content": "You are a helpful, friendly voice assistant. Keep responses concise and conversational (1-3 sentences). Return only the spoken response — no markdown, no lists."
                },
                {"role": "user", "content": text}
            ]
        )
        llm_text = response.choices[0].message.content
        print(f"LLM Output: {llm_text}")
        if llm_text:
            publish_text_event(room, "assistant", llm_text)

        # 3. TTS - stream back to frontend via LiveKit
        if audio_source is None:
            print("[Backend] Audio source not initialized; skipping TTS")
            return

        await ensure_tts_track_published(room)
        
        print("Sending to TTS...")
        async with tts_lock:
            tts_response = await openai_client.audio.speech.create(
                model="tts-1",
                voice="alloy",
                input=llm_text,
                response_format="pcm",
                stream_format="audio",
            )

            print("Streaming TTS to Room...")
            pending = bytearray()
            byte_stream = await tts_response.aiter_bytes()
            async for chunk in byte_stream:
                if not chunk:
                    continue
                pending.extend(chunk)

                while len(pending) >= TTS_BYTES_PER_FRAME:
                    frame_bytes = bytes(pending[:TTS_BYTES_PER_FRAME])
                    del pending[:TTS_BYTES_PER_FRAME]
                    frame = rtc.AudioFrame(
                        frame_bytes,
                        TTS_SAMPLE_RATE,
                        TTS_CHANNELS,
                        TTS_SAMPLES_PER_FRAME,
                    )
                    await audio_source.capture_frame(frame)

            if pending:
                if len(pending) % 2 != 0:
                    pending.append(0)
                samples_per_channel = len(pending) // (2 * TTS_CHANNELS)
                if samples_per_channel > 0:
                    frame = rtc.AudioFrame(
                        bytes(pending),
                        TTS_SAMPLE_RATE,
                        TTS_CHANNELS,
                        samples_per_channel,
                    )
                    await audio_source.capture_frame(frame)
            
        print("Done streaming TTS.")

    except Exception as e:
        print(f"Error in pipeline: {e}")

async def handle_audio_stream(track: rtc.Track, room: rtc.Room):
    audio_stream = rtc.AudioStream(track)
    buffer = bytearray()
    min_chunk_seconds = 0.5
    was_muted = track.muted
    
    print("🎧 Started listening to audio stream...")
    first_frame = True
    frame_count = 0
    
    async for event in audio_stream:
        audio_frame = event.frame

        if first_frame:
            print(f"✅ RECEIVING DATA! Sample rate: {audio_frame.sample_rate}Hz, Channels: {audio_frame.num_channels}")
            first_frame = False
            
        frame_count += 1
        
        # Log every 100 frames to show data is flowing

            
        global SAMPLE_RATE
        SAMPLE_RATE = audio_frame.sample_rate

        is_muted = track.muted

        if was_muted and not is_muted:
            print("🎙️ Track unmuted, starting new capture segment...")
            buffer.clear()

        if not is_muted:
            pcm_data = bytes(audio_frame.data)
            buffer.extend(pcm_data)

        if not was_muted and is_muted:
            buffered_seconds = len(buffer) / (2 * NUM_CHANNELS * SAMPLE_RATE)
            if buffered_seconds >= min_chunk_seconds:
                print("🔇 Track muted, sending captured segment to pipeline...")
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
        print(f"[Backend] ✅ Track subscribed: {participant.identity} - {track.kind}")
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
        print(f"[Backend] ❌ Track subscription failed: participant={participant.identity}, sid={track_sid}, error={error}")

    @room.on("track_muted")
    def on_track_muted(participant: rtc.Participant, publication: rtc.TrackPublication):
        print(f"[Backend] 🔇 Track muted: participant={participant.identity}, sid={publication.sid}")

    @room.on("track_unmuted")
    def on_track_unmuted(participant: rtc.Participant, publication: rtc.TrackPublication):
        print(f"[Backend] 🔊 Track unmuted: participant={participant.identity}, sid={publication.sid}")

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
        state_task = asyncio.create_task(log_subscription_state(room))
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
        if 'state_task' in locals():
            state_task.cancel()
        await room.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
