#  Indian Script Transliterator

A cross-platform Flutter + Flask app that converts text in Indian scripts from an image into transliterated text (Latin or another Indian script) and optionally plays pronunciation audio.

---

##  Overview

**Features**

* Extracts text from an image using **Tesseract OCR**
* Detects the text script (Hindi, Tamil, Telugu, etc.)
* Transliterates text using **Indic Transliteration**
* Generates pronunciation audio using **gTTS (Google Text-to-Speech)**
* Flutter UI to capture or upload images, transliterate, and play audio

---

##  1. Prerequisites

###  On your PC (Server)

* Python 3.8+ (tested up to 3.11)
* [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) installed and in PATH

  * **Windows**: Install from [UB Mannheim Builds](https://github.com/UB-Mannheim/tesseract/wiki)
  * **Linux (Ubuntu)**:

    ```bash
    sudo apt install tesseract-ocr tesseract-ocr-hin tesseract-ocr-tam
    ```
* Recommended: virtual environment (`venv`)

###  On your phone

* Flutter SDK (≥ 3.3.0)
* Android device or emulator with network access to your PC (same Wi-Fi network)

---

##  2. Backend Setup (Flask)

### Install dependencies

Create a `requirements.txt`:

```
Flask
flask-cors
pillow
pytesseract
indic-transliteration
gTTS
werkzeug
```

Then run:

```bash
python -m venv venv
# Activate venv
venv\Scripts\activate   # Windows
# or
source venv/bin/activate  # macOS/Linux

pip install -r requirements.txt
```

### Configure server IP

Edit **`server.py`** and set your local IP:

```python
SERVER_IP = "192.168.31.242"
```

(Use your PC’s IP address accessible from your phone.)

### Run the server

```bash
python server.py
```

Expected output:

```
 Starting server on 0.0.0.0:5000
 Make sure PHONE can access: http://192.168.31.242:5000
```

### Test

Visit in browser:

```
http://192.168.31.242:5000/
```

You should see:

```json
{"status": "running", "service": "Indian Script Transliteration API"}
```

---

##  3. Mobile App Setup (Flutter)

### Edit environment in `pubspec.yaml`

```yaml
environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.10.0'
```

### Dependencies

Ensure the following are included:

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.1.0
  image_picker: ^0.8.7+4
  audioplayers: ^6.5.1
  mime: ^1.0.1
  path: ^1.8.3
  http_parser: ^4.0.0
```

Then run:

```bash
flutter pub get
```

### Configure server URL

In **`lib/main.dart`**, set:

```dart
const String BASE_URL = "http://192.168.31.242:5000";
```

Make sure there are **two slashes** after `http:`.

### Android Manifest fixes

In `android/app/src/main/AndroidManifest.xml`, ensure:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

and inside `<application>`:

```xml
android:usesCleartextTraffic="true"
```

(Remove `package="..."` from manifest if Gradle complains; `namespace` in `build.gradle` handles that.)

### Run Flutter app

```bash
flutter run -d <device-id>
```

Then pick an image → tap **Upload & Transliterate** → test **Play Pronunciation**.

---

##  4. API Usage (for testing)

Upload an image manually with `curl`:

```bash
curl -X POST "http://192.168.31.242:5000/transliterate" \
  -F "file=@image.jpg" \
  -F "target_script=latin" \
  -F "ocr_lang=eng+hin+tam+tel+kan+mal+ben+guj+pan"
```

Example JSON response:

```json
{
  "original_text": "தமிழ் எழுத்து",
  "transliterated_text": "tamil eḻuttu",
  "detected_script": "tamil",
  "target_script": "latin",
  "langCode": "ta",
  "audio_url": "http://192.168.31.242:5000/audio/tts_12345.mp3",
  "error": ""
}
```

---

##  5. Troubleshooting

###  “Upload failed” or “Server error 500”

* Check Flask console output for stack trace.
* Ensure Flask and Flutter both use same IP/port (`192.168.31.242:5000`).
* Verify Tesseract OCR is installed and callable.

### Audio not playing

* Try opening `audio_url` in your phone’s browser — if it plays, the network is OK.
* Check `AndroidManifest.xml` has `usesCleartextTraffic="true"`.
* Ensure you didn’t misspell the URL (`http://`, not `http:/`).

###  OCR inaccurate

* Improve image lighting and clarity.
* Install all relevant Tesseract language packs.
* Optionally preprocess images with OpenCV filters for denoising and contrast.

---

##  Project Structure

```
project-root/
├─ server.py
├─ audio/
│   └─ tts_xxx.mp3
├─ requirements.txt
├─ lib/
│   └─ main.dart
├─ android/
│   └─ app/
│       └─ src/
│           └─ main/
│               └─ AndroidManifest.xml
└─ README.md
```

---

##  6. Technology Stack

| Component        | Technology                       | Description                   |
| ---------------- | -------------------------------- | ----------------------------- |
| OCR              | **pytesseract (Tesseract OCR)**  | Extracts text from image      |
| Script detection | Unicode range logic              | Identifies script family      |
| Transliteration  | **indic-transliteration**        | Converts text between scripts |
| TTS              | **gTTS (Google Text-to-Speech)** | Generates pronunciation audio |
| Frontend         | **Flutter (Dart)**               | Mobile interface              |
| Backend          | **Flask (Python)**               | REST API and media hosting    |

---

##  7. Quick Summary

| Step                | Command                                             |
| ------------------- | --------------------------------------------------- |
| Install server deps | `pip install -r requirements.txt`                   |
| Run Flask backend   | `python server.py`                                  |
| Configure IP        | Set both in `server.py` & `main.dart`               |
| Run Flutter app     | `flutter run -d <your-device>`                      |
| Test connection     | Visit `http://<SERVER_IP>:5000/` from phone browser |

---

