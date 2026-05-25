import array
import sys
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse

# Force plain CPU execution mappings
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"

from kokoro import KPipeline

app = FastAPI()
SAMPLE_RATE = 24000

try:
    pipeline = KPipeline(lang_code='a')
except Exception as e:
    print(f"Pipeline Init Alert: {e}")
    pipeline = None

@app.post("/tts")
async def text_to_speech(data: dict):
    if pipeline is None:
        raise HTTPException(status_code=500, detail="TTS Pipeline not initialized")
        
    text = data.get("text", "")
    voice = data.get("voice", "af_heart")
    
    if not text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")
        
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

    def audio_stream_generator():
        try:
            generator = pipeline(text, voice=voice, speed=1.0)
            
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

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
