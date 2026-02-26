import os
import aiohttp
from aiohttp import web
import aiohttp_cors
from livekit.api import AccessToken, VideoGrants
from dotenv import load_dotenv

load_dotenv()

async def handle_token(request):
    room_name = request.query.get("roomName", "voice-room")
    participant_name = request.query.get("participantName", "user")

    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    url = os.getenv("LIVEKIT_URL")

    if not api_key or not api_secret or not url:
        return web.json_response({"error": "Missing LiveKit credentials"}, status=500)

    token = AccessToken(api_key, api_secret) \
        .with_identity(participant_name) \
        .with_name(participant_name) \
        .with_grants(VideoGrants(
            room_join=True, 
            room=room_name,
            can_publish=True,     # Allow publishing tracks
               # Automatically subscribe to tracks when joining
        ))

    print(f"[TokenServer] Generated token for {participant_name} with pub/sub permissions")

    return web.json_response({
        "token": token.to_jwt(),
        "url": url,
    })

app = web.Application()
cors = aiohttp_cors.setup(app, defaults={
    "*": aiohttp_cors.ResourceOptions(
        allow_credentials=True,
        expose_headers="*",
        allow_headers="*"
    )
})

route = app.router.add_get('/getToken', handle_token)
cors.add(route)

if __name__ == "__main__":
    web.run_app(app, port=8002)
