# server.py
from flask import Flask, request, jsonify, send_file, Response, abort
from flask_cors import CORS
from PIL import Image, UnidentifiedImageError
import io, os, time, tempfile, uuid, re, traceback
import pytesseract
from indic_transliteration.sanscript import transliterate
from gtts import gTTS
from werkzeug.utils import secure_filename
from pathlib import Path
from typing import Tuple

app = Flask(__name__)
CORS(app)

# === CONFIG ===
AUDIO_FOLDER = "audio"
os.makedirs(AUDIO_FOLDER, exist_ok=True)
app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024  # 10 MB limit

# IMPORTANT: set this to your PC's LAN IP reachable from phone (used as fallback)
SERVER_IP = "192.168.31.242"

# If tesseract not in PATH on Windows, uncomment and set the path:
# pytesseract.pytesseract.tesseract_cmd = r"C:\Program Files\Tesseract-OCR\tesseract.exe"

# Unicode ranges for script detection
SCRIPT_RANGES = {
    "devanagari": [(0x0900, 0x097F)],
    "bengali":    [(0x0980, 0x09FF)],
    "gurmukhi":   [(0x0A00, 0x0A7F)],
    "gujarati":   [(0x0A80, 0x0AFF)],
    "oriya":      [(0x0B00, 0x0B7F)],
    "tamil":      [(0x0B80, 0x0BFF)],
    "telugu":     [(0x0C00, 0x0C7F)],
    "kannada":    [(0x0C80, 0x0CFF)],
    "malayalam":  [(0x0D00, 0x0D7F)],
    "latin":      [(0x0000, 0x007F)],
}

# Map script name -> sanscript scheme
SANSCRIPT_MAP = {
    "devanagari": "devanagari",
    "bengali": "bengali",
    "gurmukhi": "gurmukhi",
    "gujarati": "gujarati",
    "oriya": "oriya",
    "tamil": "tamil",
    "telugu": "telugu",
    "kannada": "kannada",
    "malayalam": "malayalam",
    # use ITRANS for Latin ascii-friendliness
    "latin": "itrans",
}

# TTS language codes for gTTS
TTS_LANG_MAP = {
    "devanagari": "hi",
    "bengali": "bn",
    "gurmukhi": "pa",
    "gujarati": "gu",
    "oriya": "or",
    "tamil": "ta",
    "telugu": "te",
    "kannada": "kn",
    "malayalam": "ml",
    "latin": "en",
}

DEFAULT_OCR_LANG = "eng+hin+tam+tel+kan+mal+ben+guj+pan"


def detect_script(text: str) -> str:
    if not text or not text.strip():
        return "unknown"
    counts = {s: 0 for s in SCRIPT_RANGES}
    for ch in text:
        cp = ord(ch)
        for script, ranges in SCRIPT_RANGES.items():
            for start, end in ranges:
                if start <= cp <= end:
                    counts[script] += 1
                    break
    best = max(counts.items(), key=lambda x: x[1])
    return best[0] if best[1] > 0 else "unknown"

def perform_ocr_from_bytes(file_bytes: bytes, ocr_lang: str = None) -> str:
    ocr_lang = ocr_lang or DEFAULT_OCR_LANG
    try:
        image = Image.open(io.BytesIO(file_bytes)).convert("RGB")
    except UnidentifiedImageError:
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".jpg")
        try:
            tmp.write(file_bytes)
            tmp.close()
            image = Image.open(tmp.name).convert("RGB")
        finally:
            try:
                os.remove(tmp.name)
            except Exception:
                pass

    try:
        text = pytesseract.image_to_string(image, lang=ocr_lang)
    except Exception as e:
        app.logger.warning("OCR multi-lang failed: %s", e)
        try:
            text = pytesseract.image_to_string(image, lang="eng")
        except Exception as e2:
            app.logger.exception("Fallback OCR failed: %s", e2)
            text = ""
    return (text or "").strip()

def schwa_delete_for_devanagari_to_latin(transliterated_text: str) -> str:
    if not transliterated_text:
        return transliterated_text
    text = re.sub(r'a\b', '', transliterated_text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text

def _safe_tts_save_chunks(text: str, lang: str, out_path: str) -> bool:
    """
    For very long text gTTS or the network call could fail.
    Split into smaller sentences/chunks and append them to produce a single mp3 file.
    Returns True on success.
    """
    try:
        
        pieces = re.split(r'(?<=[\.\?\!।])\s+', text)
       
        if len(pieces) == 0:
            pieces = [text]
        
        if len(pieces) > 12:
            joined = []
            tmp = ""
            for p in pieces:
                if len(tmp) + len(p) > 300:
                    joined.append(tmp)
                    tmp = p
                else:
                    tmp = (tmp + " " + p).strip()
            if tmp:
                joined.append(tmp)
            pieces = joined

        
        temp_files = []
        for i, piece in enumerate(pieces):
            piece = piece.strip()
            if not piece:
                continue
            tmp_name = f"{out_path}.{i}.mp3"
            try:
                tts = gTTS(text=piece, lang=lang)
                tts.save(tmp_name)
                temp_files.append(tmp_name)
            except Exception as e:
                app.logger.exception("gTTS chunk save failed: %s", e)
                # cleanup partial files
                for tf in temp_files:
                    try:
                        os.remove(tf)
                    except Exception:
                        pass
                return False

        # Merge temp mp3 files into one by concatenation (works with gTTS-generated mp3s for many players)
        with open(out_path, "wb") as wfd:
            for tf in temp_files:
                with open(tf, "rb") as fd:
                    wfd.write(fd.read())
        # remove temp files
        for tf in temp_files:
            try:
                os.remove(tf)
            except Exception:
                pass
        return True
    except Exception as e:
        app.logger.exception("Error in _safe_tts_save_chunks: %s", e)
        return False

def generate_tts_audio(text: str, lang_code: str) -> str:
    """
    Generate TTS mp3 and return filename (or '' on error).
    Uses chunk-saving fallback to be robust.
    """
    try:
        os.makedirs(AUDIO_FOLDER, exist_ok=True)
        filename = f"tts_{uuid.uuid4().hex}.mp3"
        out_path = os.path.join(AUDIO_FOLDER, filename)
        
        try:
            tts = gTTS(text=text, lang=lang_code)
            tts.save(out_path)
            if os.path.exists(out_path):
                return filename
        except Exception as e:
            app.logger.warning("gTTS single-save failed: %s. Trying chunked fallback.", e)
        # fallback: chunked approach
        ok = _safe_tts_save_chunks(text, lang_code, out_path)
        if ok and os.path.exists(out_path):
            return filename
        app.logger.error("TTS generation ultimately failed for text (len=%d)", len(text))
        return ""
    except Exception as e:
        app.logger.exception("TTS error: %s", e)
        return ""


def send_file_partial(path: str):
    """
    Serve file supporting Range requests, returning a Flask Response.
    """
    file_size = os.path.getsize(path)
    range_header = request.headers.get('Range', None)
    if not range_header:
        return send_file(path, mimetype="audio/mpeg", conditional=True)

    # parse Range header "bytes=start-end"
    match = re.search(r"bytes=(\d+)-(\d*)", range_header)
    if not match:
        return send_file(path, mimetype="audio/mpeg", conditional=True)

    start = int(match.group(1))
    end = match.group(2)
    end = int(end) if end else file_size - 1
    if start >= file_size:
        return Response(status=416)  # requested range not satisfiable

    length = end - start + 1
    with open(path, 'rb') as f:
        f.seek(start)
        data = f.read(length)

    rv = Response(data, 206, mimetype="audio/mpeg", direct_passthrough=True)
    rv.headers.add('Content-Range', f'bytes {start}-{end}/{file_size}')
    rv.headers.add('Accept-Ranges', 'bytes')
    rv.headers.add('Content-Length', str(length))
    return rv


@app.route('/transliterate', methods=['POST'])
def transliterate_image():
    try:
        if 'file' not in request.files:
            return jsonify({'error': 'No file uploaded'}), 400
        file = request.files['file']
        if file.filename == '':
            return jsonify({'error': 'Empty filename'}), 400

        target_script = (request.form.get('target_script') or 'latin').lower()
        ocr_lang = request.form.get('ocr_lang') or DEFAULT_OCR_LANG

        file_bytes = file.read()
        if not file_bytes:
            return jsonify({'error': 'Empty file'}), 400

        start = time.time()
        extracted = perform_ocr_from_bytes(file_bytes, ocr_lang=ocr_lang)
        app.logger.info("OCR time: %.2fs len=%d", time.time() - start, len(extracted))

        if not extracted:
            return jsonify({
                "original_text": "",
                "transliterated_text": "",
                "detected_script": "unknown",
                "target_script": target_script,
                "langCode": "",
                "audio_url": "",
                "error": "No text found in image"
            }), 200

        # detect & transliterate
        detected_script = detect_script(extracted)
        from_scheme = SANSCRIPT_MAP.get(detected_script, "iast")
        to_scheme = SANSCRIPT_MAP.get(target_script, "itrans")
        try:
            if from_scheme == to_scheme:
                transliterated = extracted
            else:
                transliterated = transliterate(extracted, from_scheme, to_scheme)
        except Exception as e:
            app.logger.exception("Transliteration error: %s", e)
            try:
                intermediate = transliterate(extracted, from_scheme, "iast")
                transliterated = transliterate(intermediate, "iast", to_scheme)
            except Exception as e2:
                app.logger.exception("Fallback transliteration failed: %s", e2)
                transliterated = extracted

        # schwa deletion heuristic only for dev->latin (conservative)
        if detected_script == 'devanagari' and target_script == 'latin':
            transliterated = schwa_delete_for_devanagari_to_latin(transliterated)

        # TTS: pick language code
        tts_lang = TTS_LANG_MAP.get(detected_script, TTS_LANG_MAP.get(target_script, "en"))
        # prefer original-language text for tts (more natural)
        tts_text_for_generation = extracted if detected_script != 'latin' else transliterated

        audio_filename = ""
        if tts_text_for_generation.strip():
            audio_filename = generate_tts_audio(tts_text_for_generation, tts_lang)

        audio_url = ""
        if audio_filename:
            # Prefer request.host if it looks reachable; otherwise fallback to SERVER_IP
            host = request.host.split(':')[0] if request.host else ""
            # If host is obvious loopback, fallback
            if host in ("127.0.0.1", "localhost", ""):
                host_to_use = SERVER_IP
            else:
                # Sometimes request.host is "0.0.0.0" which is not reachable — fallback then too
                if host in ("0.0.0.0",):
                    host_to_use = SERVER_IP
                else:
                    host_to_use = host
            audio_url = f"http://{host_to_use}:5000/audio/{secure_filename(audio_filename)}"
            app.logger.info("Audio URL: %s", audio_url)

        return jsonify({
            "original_text": extracted,
            "transliterated_text": transliterated,
            "detected_script": detected_script,
            "target_script": target_script,
            "langCode": f"{tts_lang}",
            "audio_url": audio_url,
            "error": ""
        }), 200

    except Exception as e:
        app.logger.exception("Server exception: %s", e)
        return jsonify({'error': str(e)}), 500

@app.route('/audio/<path:filename>')
def serve_audio(filename):
    try:
        file_path = os.path.join(AUDIO_FOLDER, secure_filename(filename))
        if not os.path.exists(file_path):
            return jsonify({"error": "Audio file not found"}), 404
        # Support Range requests for streaming
        return send_file_partial(file_path)
    except Exception as e:
        app.logger.exception("serve_audio error: %s", e)
        return jsonify({"error": str(e)}), 500

@app.route('/', methods=['GET'])
def home():
    return jsonify({"status": "running", "service": "Indian Script Transliteration API", "version": "1.5"}), 200


if __name__ == '__main__':
    print("🚀 Starting server on 0.0.0.0:5000")
    print(f"📡 Make sure PHONE can access: http://{SERVER_IP}:5000")
    app.run(host='0.0.0.0', port=5000, debug=True)
