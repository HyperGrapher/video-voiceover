## BUILD PYTHON BACKEND
** This method works on both intel and apple slicon based macs but slow **

python 3.12 is a requirement, doesn;t work on pyton 3.13+ 



- create venv `python3 `
- install requirements.txt
- build executable from app.py

```py
pyinstaller --onefile \
  --collect-all transformers \
  --collect-all spacy \
  --collect-all en_core_web_sm \
  --collect-all uvicorn \
  --collect-all scipy \
  --collect-data soundfile \
  --collect-data language_tags \
  --collect-data phonemizer \
  --collect-data misaki \
  --collect-data espeakng_loader \
  --copy-metadata torch \
  --copy-metadata transformers \
  --copy-metadata fastapi \
  --copy-metadata kokoro \
  --copy-metadata misaki \
  app.py
```