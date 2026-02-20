import whisper
from fastapi import FastAPI, UploadFile, File, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel
import os
import tempfile
from typing import Optional
from urllib.parse import unquote
import io
import soundfile as sf
import numpy as np
from kokoro import KPipeline

app = FastAPI()

# Load the model once when the server starts
# Options: "tiny", "base", "small", "medium", "large"
model = whisper.load_model("base")

# Initialize Kokoro TTS pipeline
tts_pipeline = KPipeline(lang_code='a')

class TTSRequest(BaseModel):
    text: str
    voice: Optional[str] = "am_eric"
    speed: Optional[float] = 1.0


@app.post("/transcribe")
async def transcribe_audio(file: Optional[UploadFile] = File(None), file_path: Optional[str] = Query(None)):
    """
    Transcribe audio from either an uploaded file or a file path.
    - Upload file: multipart/form-data with 'file' field
    - File path: POST /transcribe?file_path=/path/to/file.wav
    """
    temp_file = None
    try:
        if file:
            # Handle uploaded file
            temp_dir = tempfile.gettempdir()
            # Create a unique temp file with proper extension
            import uuid
            unique_name = f"{uuid.uuid4()}_{file.filename}"
            temp_file = os.path.join(temp_dir, unique_name)
            
            # Write and close the file properly before transcription
            with open(temp_file, "wb") as buffer:
                content = await file.read()
                buffer.write(content)
            
            if not os.path.exists(temp_file):
                raise Exception(f"Failed to save temp file at {temp_file}")
            
            file_size = os.path.getsize(temp_file)
            if file_size == 0:
                raise Exception("Uploaded file is empty")
            
            filename = file.filename
            path_to_transcribe = temp_file
            
        elif file_path:
            # Handle file path - decode URL encoding and normalize path
            decoded_path = unquote(file_path)
            normalized_path = os.path.normpath(decoded_path)
            
            if not os.path.exists(normalized_path):
                raise HTTPException(status_code=404, detail=f"File not found: {normalized_path}")
            
            if not os.path.isfile(normalized_path):
                raise HTTPException(status_code=400, detail=f"Path is not a file: {normalized_path}")
            
            filename = os.path.basename(normalized_path)
            path_to_transcribe = normalized_path
            
        else:
            raise HTTPException(status_code=400, detail="Either 'file' (upload) or 'file_path' (query param) must be provided")
        
        # Transcribe using Whisper
        result = model.transcribe(path_to_transcribe)
        
        return {"filename": filename, "transcription": result["text"]}
    
    except HTTPException:
        raise
    except Exception as e:
        error_detail = str(e)
        raise HTTPException(status_code=500, detail=error_detail)
    finally:
        # Clean up temp file if it was created
        if temp_file and os.path.exists(temp_file):
            try:
                os.remove(temp_file)
            except:
                pass


@app.post("/tts")
async def text_to_speech(request: TTSRequest):
    """
    Convert text to speech and return audio as WAV byte array.
    
    Parameters:
    - text: The text to convert to speech
    - voice: Voice to use (default: "am_eric")
    - speed: Speech speed multiplier (default: 1.0)
    
    Returns: WAV audio file as bytes
    """
    try:
        if not request.text or not request.text.strip():
            raise HTTPException(status_code=400, detail="Text cannot be empty")
        
        # Generate audio using Kokoro TTS
        generator = tts_pipeline(
            request.text,
            voice=request.voice,
            speed=request.speed,
            split_pattern=r'\n+'
        )
        
        # Collect all audio chunks
        audio_chunks = []
        for i, (gs, ps, audio) in enumerate(generator):
            audio_chunks.append(audio)
        
        if not audio_chunks:
            raise HTTPException(status_code=500, detail="Failed to generate audio")
        
        # Concatenate all audio chunks
        full_audio = np.concatenate(audio_chunks)
        
        # Convert to WAV byte array
        buffer = io.BytesIO()
        sf.write(buffer, full_audio, 24000, format='WAV')
        buffer.seek(0)
        audio_bytes = buffer.read()
        
        # Return as audio/wav response
        return Response(
            content=audio_bytes,
            media_type="audio/wav",
            headers={
                "Content-Disposition": "attachment; filename=tts_output.wav"
            }
        )
    
    except HTTPException:
        raise
    except Exception as e:
        error_detail = str(e)
        raise HTTPException(status_code=500, detail=f"TTS generation failed: {error_detail}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)