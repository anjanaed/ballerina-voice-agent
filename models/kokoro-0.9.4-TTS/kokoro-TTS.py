from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
import numpy as np
import soundfile as sf
from kokoro import KPipeline


pipeline = KPipeline(lang_code="a")


class TTSHandler(BaseHTTPRequestHandler):
    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/synthesize":
            self._send_json(404, {"error": "Endpoint not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length)
            data = json.loads(body.decode("utf-8"))

            text = data.get("text", "").strip()
            voice = data.get("voice", "am_eric")
            speed = float(data.get("speed", 1.0))
            split_pattern = data.get("split_pattern", r"\n+")

            if not text:
                self._send_json(400, {"error": "'text' is required"})
                return

            generator = pipeline(
                text,
                voice=voice,
                speed=speed,
                split_pattern=split_pattern,
            )

            chunks = []
            for _, _, audio in generator:
                chunks.append(audio)

            if not chunks:
                self._send_json(500, {"error": "No audio generated"})
                return

            audio = np.concatenate(chunks)

            buffer = io.BytesIO()
            sf.write(buffer, audio, 24000, format="WAV")
            audio_bytes = buffer.getvalue()

            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio_bytes)))
            self.end_headers()
            self.wfile.write(audio_bytes)

        except json.JSONDecodeError:
            self._send_json(400, {"error": "Invalid JSON body"})
        except Exception as exc:
            self._send_json(500, {"error": str(exc)})


def run_server(host: str = "127.0.0.1", port: int = 8005) -> None:
    server = HTTPServer((host, port), TTSHandler)
    print(f"TTS server running on http://{host}:{port}")
    print("POST JSON to /synthesize with: text, voice(optional), speed(optional)")
    server.serve_forever()


if __name__ == "__main__":
    run_server()