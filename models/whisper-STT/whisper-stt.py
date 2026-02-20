import whisper
import tempfile
import uuid
import os
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()

# Load the model once when the server starts
# Options: "tiny", "base", "small", "medium", "large"
model = whisper.load_model("base")


@app.post("/transcribe")
async def transcribe_audio(request: Request):
    """
    Transcribe audio from raw bytes in the request body.
    Accepts: audio/wav or application/octet-stream
    Returns: { "transcription": "..." }
    """
    data = await request.body()
    if not data:
        raise HTTPException(status_code=400, detail="Request body is empty")

    temp_file = os.path.join(tempfile.gettempdir(), f"{uuid.uuid4()}.wav")
    try:
        with open(temp_file, "wb") as f:
            f.write(data)
        result = model.transcribe(temp_file)
        return {"transcription": result["text"]}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if os.path.exists(temp_file):
            os.remove(temp_file)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)