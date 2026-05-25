import io
import os
import sys
import soundfile as sf  # FIX: Add this missing import statement!

# Force plain CPU execution mappings
os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "0"

# GLOBAL CRASH CATCHER FOR PYINSTALLER DIAGNOSTICS
try:
    from kokoro import KPipeline
except Exception as e:
    import traceback
    print("\n[CRITICAL INITIALIZATION CRASH]")
    traceback.print_exc()
    sys.exit(1)

from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse

app = FastAPI()

try:
    print("Initializing Kokoro KPipeline...")
    pipeline = KPipeline(lang_code='a')
    print("KPipeline successfully initialized!")
except Exception as e:
    import traceback
    print("\n[CRITICAL PIPELINE INITIALIZATION CRASH]")
    traceback.print_exc()
    sys.exit(1)

@app.post("/tts")
async def text_to_speech(data: dict):
    if pipeline is None:
        raise HTTPException(status_code=500, detail="TTS Pipeline not initialized")
        
    text = data.get("text", "")
    voice = data.get("voice", "af_heart")
    
    if not text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")
        
    try:
        generator = pipeline(text, voice=voice, speed=1.0)
        
        # 1. Use pure Python arrays instead of NumPy vectors
        combined_samples = []
        
        for _, _, audio in generator:
            if audio is not None:
                # Convert the raw array data directly to a clean Python float list
                if hasattr(audio, "tolist"):
                    combined_samples.extend(audio.tolist())
                else:
                    combined_samples.extend(list(audio))
                    
        if not combined_samples:
            raise HTTPException(status_code=500, detail="Zero audio frames compiled")
            
        # 2. Write the raw float list data directly to standard WAV format
        buffer = io.BytesIO()
        sf.write(buffer, combined_samples, 24000, format='WAV')
        buffer.seek(0)
        
        return StreamingResponse(buffer, media_type="audio/wav")
        
    except Exception as e:
        print(f"CRASH LOG EXCEPTION: {e}")
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn
    print("Starting production Uvicorn engine on port 8000...")
    # This forces the standalone binary to anchor the thread and listen for requests
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")