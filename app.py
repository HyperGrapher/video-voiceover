import io
import soundfile as sf
from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse

# Force plain CPU execution mappings
import os
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"

from kokoro import KPipeline

app = FastAPI()

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
        
    def audio_stream_generator():
        try:
            generator = pipeline(text, voice=voice, speed=1.0)
            
            for _, _, audio in generator:
                if audio is not None and len(audio) > 0:
                    # Convert the generator's current audio chunk to list
                    if hasattr(audio, "tolist"):
                        chunk_list = audio.tolist()
                    else:
                        chunk_list = list(audio)
                    
                    # Encode ONLY this small chunk into raw WAV bytes
                    buffer = io.BytesIO()
                    sf.write(buffer, chunk_list, 24000, format='WAV')
                    chunk_bytes = buffer.getvalue()
                    
                    # Yield the raw bytes chunk down the network stream immediately
                    yield chunk_bytes
        except Exception as e:
            print(f"Stream generation exception: {e}")

    return StreamingResponse(audio_stream_generator(), media_type="audio/wav")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
