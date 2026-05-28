# most of imports exist just add what is missing
import array
import io
import re
import sys
import tempfile
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response, StreamingResponse
import soundfile as sf

from alignment.approximate import build_words_document
from alignment.forced import ForcedWordAligner

# Force plain CPU execution mappings
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"

from kokoro import KPipeline

app = FastAPI()
SAMPLE_RATE = 24000
MAX_CHUNK_CHARS = 140
MAX_CHUNK_WORDS = 20
forced_aligner = None



@app.post("/align/words")
async def align_words(
    transcript: str = Form(...),
    duration: float = Form(...),
    audio: UploadFile = File(...),
):
    global forced_aligner

    if duration <= 0:
        raise HTTPException(status_code=400, detail="Duration must be positive")

    suffix = os.path.splitext(audio.filename or "")[1] or ".m4a"
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temporary_audio:
            temporary_audio.write(await audio.read())
            audio_path = temporary_audio.name

        if forced_aligner is None:
            forced_aligner = ForcedWordAligner()

        words = forced_aligner.align(transcript, duration, audio_path)
        return {
            "text": transcript,
            "sampleRate": SAMPLE_RATE,
            "duration": duration,
            "mode": "forced",
            "words": [word.to_dict() for word in words],
        }
    except Exception as e:
        print(f"Forced alignment exception: {e}")
        document = build_words_document(transcript, duration, SAMPLE_RATE)
        document["mode"] = "approximate"
        document["warning"] = str(e)
        return document
    finally:
        if "audio_path" in locals():
            try:
                os.remove(audio_path)
            except OSError:
                pass
