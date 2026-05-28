import array
import io
import re
import sys
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
import soundfile as sf

# Force plain CPU execution mappings
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"

from kokoro import KPipeline

app = FastAPI()
SAMPLE_RATE = 24000
MAX_CHUNK_CHARS = 140
MAX_CHUNK_WORDS = 20

try:
    pipeline = KPipeline(lang_code='a')
except Exception as e:
    print(f"Pipeline Init Alert: {e}")
    pipeline = None

def split_text_for_low_latency(source):
    normalized = re.sub(r"\s+", " ", source.strip())
    sentence_parts = re.split(r"(?<=[.!?;:])\s+", normalized)
    chunks = []

    for sentence in sentence_parts:
        words = sentence.split()
        current_words = []
        current_length = 0

        for word in words:
            next_length = current_length + len(word) + (1 if current_words else 0)
            if current_words and (
                len(current_words) >= MAX_CHUNK_WORDS
                or next_length > MAX_CHUNK_CHARS
            ):
                chunks.append(" ".join(current_words))
                current_words = []
                current_length = 0

            current_words.append(word)
            current_length += len(word) + (1 if current_length else 0)

        if current_words:
            chunks.append(" ".join(current_words))

    return chunks or [normalized]

def pcm16_bytes(audio):
    if hasattr(audio, "tolist"):
        samples = audio.tolist()
    else:
        samples = list(audio)

    pcm = array.array("h")
    pcm.fromlist([
        max(-32768, min(32767, int(float(sample) * 32767.0)))
        for sample in samples
    ])

    if sys.byteorder != "little":
        pcm.byteswap()

    return pcm.tobytes()

def audio_samples(audio):
    if hasattr(audio, "tolist"):
        return audio.tolist()

    return list(audio)

def validate_request(data):
    if pipeline is None:
        raise HTTPException(status_code=500, detail="TTS Pipeline not initialized")
        
    text = data.get("text", "")
    voice = data.get("voice", "af_heart")
    
    if not text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    return text.strip(), voice

@app.post("/tts")
async def text_to_speech(data: dict):
    text, voice = validate_request(data)

    def audio_stream_generator():
        try:
            for chunk in split_text_for_low_latency(text):
                generator = pipeline(chunk, voice=voice, speed=1.0)

                for _, _, audio in generator:
                    if audio is not None and len(audio) > 0:
                        yield pcm16_bytes(audio)
        except Exception as e:
            print(f"Stream generation exception: {e}")

    return StreamingResponse(
        audio_stream_generator(),
        media_type="application/octet-stream",
        headers={
            "X-Audio-Sample-Rate": str(SAMPLE_RATE),
            "X-Audio-Channels": "1",
            "X-Audio-Format": "pcm_s16le",
        },
    )

@app.post("/tts-file")
async def text_to_speech_file(data: dict):
    text, voice = validate_request(data)

    try:
        samples = []
        generator = pipeline(text, voice=voice, speed=1.0)

        for _, _, audio in generator:
            if audio is not None and len(audio) > 0:
                samples.extend(audio_samples(audio))

        if not samples:
            raise HTTPException(status_code=500, detail="No audio was generated")

        buffer = io.BytesIO()
        sf.write(buffer, samples, SAMPLE_RATE, format="WAV", subtype="PCM_16")

        return Response(
            content=buffer.getvalue(),
            media_type="audio/wav",
            headers={
                "Content-Disposition": 'attachment; filename="speech.wav"',
                "X-Audio-Sample-Rate": str(SAMPLE_RATE),
            },
        )
    except HTTPException:
        raise
    except Exception as e:
        print(f"File generation exception: {e}")
        raise HTTPException(status_code=500, detail="Audio generation failed")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
