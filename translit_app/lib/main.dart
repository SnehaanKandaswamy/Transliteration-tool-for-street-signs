// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:audioplayers/audioplayers.dart';

/// IMPORTANT: Replace with your PC IP reachable from phone
const String BASE_URL = "http://192.168.31.242:5000";
const String TRANSLITERATE_ENDPOINT = "$BASE_URL/transliterate";

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Indian Script Transliterator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        fontFamily: 'Poppins',
      ),
      home: const TransliteratorPage(),
    );
  }
}

class TransliteratorPage extends StatefulWidget {
  const TransliteratorPage({super.key});
  @override
  State<TransliteratorPage> createState() => _TransliteratorPageState();
}

class _TransliteratorPageState extends State<TransliteratorPage> {
  File? _imageFile;
  final _picker = ImagePicker();
  final AudioPlayer _player = AudioPlayer();

  bool _loading = false;
  String _error = '';
  String _original = '';
  String _transliterated = '';
  String _detectedScript = '';
  String _audioUrl = '';
  String _targetScript = 'latin';

  final List<String> _scripts = [
    'devanagari',
    'bengali',
    'gurmukhi',
    'gujarati',
    'oriya',
    'tamil',
    'telugu',
    'kannada',
    'malayalam',
    'latin',
  ];

  @override
  void initState() {
    super.initState();
    _player.setPlayerMode(PlayerMode.mediaPlayer);
    // Optional debug listeners
    _player.onPlayerStateChanged.listen((state) {
      debugPrint('player state: $state');
    });
    _player.onPlayerComplete.listen((_) {
      debugPrint('player complete');
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final XFile? file = await _picker.pickImage(source: src, imageQuality: 90);
      if (file == null) return;
      if (src == ImageSource.camera) {
        // small delay after camera captures on some devices
        await Future.delayed(const Duration(milliseconds: 400));
      }
      setState(() {
        _imageFile = File(file.path);
        _error = '';
      });
    } catch (e) {
      setState(() => _error = 'Image pick failed: $e');
    }
  }

  Future<void> _uploadImage() async {
    if (_imageFile == null) {
      setState(() => _error = 'No image selected.');
      return;
    }

    setState(() {
      _loading = true;
      _error = '';
      _original = '';
      _transliterated = '';
      _detectedScript = '';
      _audioUrl = '';
    });

    try {
      final uri = Uri.parse(TRANSLITERATE_ENDPOINT);
      final request = http.MultipartRequest('POST', uri);

      request.fields['target_script'] = _targetScript;
      request.fields['ocr_lang'] = 'eng+hin+tam+tel+kan+mal+ben+guj+pan';

      final mimeType = lookupMimeType(_imageFile!.path) ?? 'image/jpeg';
      final parts = mimeType.split('/');
      final filePart = await http.MultipartFile.fromPath(
        'file',
        _imageFile!.path,
        contentType: MediaType(parts[0], parts[1]),
        filename: path.basename(_imageFile!.path),
      );
      request.files.add(filePart);

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final Map<String, dynamic> body = jsonDecode(response.body);
        setState(() {
          _original = body['original_text'] ?? '';
          _transliterated = body['transliterated_text'] ?? '';
          _detectedScript = body['detected_script'] ?? '';
          _audioUrl = body['audio_url'] ?? '';
          _error = (body['error'] ?? '').toString();
        });
      } else {
        setState(() => _error = 'Server error ${response.statusCode}: ${response.reasonPhrase}');
      }
    } on TimeoutException catch (te) {
      setState(() => _error = 'Upload timed out: $te');
    } on SocketException catch (se) {
      setState(() => _error = 'Network error: $se. Is server reachable from this phone?');
    } catch (e) {
      setState(() => _error = 'Upload failed: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  /// Robust playback: try streaming first, then fallback to bytes
  Future<void> _playAudio() async {
    setState(() => _error = '');

    if (_audioUrl.isEmpty) {
      setState(() => _error = 'No audio available.');
      return;
    }

    final uri = Uri.tryParse(_audioUrl);
    if (uri == null) {
      setState(() => _error = 'Invalid audio URL.');
      return;
    }

    try {
      // quick probe
      final probe = await http.get(uri).timeout(const Duration(seconds: 8));
      if (probe.statusCode != 200) {
        setState(() => _error = 'Audio not reachable (HTTP ${probe.statusCode}). Open URL in phone browser to debug.');
        return;
      }

      await _player.stop();
      await _player.setPlayerMode(PlayerMode.mediaPlayer);

      // Try streaming
      try {
        await _player.play(UrlSource(_audioUrl));
        await Future.delayed(const Duration(milliseconds: 400));
        final state = _player.state;
        if (state == PlayerState.playing || state == PlayerState.completed) {
          return;
        }
      } catch (e) {
        debugPrint('streaming error: $e');
      }

      // Fallback: download bytes and play
      final getResp = await http.get(uri).timeout(const Duration(seconds: 20));
      if (getResp.statusCode == 200 && getResp.bodyBytes.isNotEmpty) {
        await _player.stop();
        await _player.setPlayerMode(PlayerMode.mediaPlayer);
        await _player.play(BytesSource(getResp.bodyBytes));
        await Future.delayed(const Duration(milliseconds: 300));
        final postState = _player.state;
        if (postState == PlayerState.playing || postState == PlayerState.completed) {
          return;
        } else {
          setState(() => _error = 'Playback failed to start (state: $postState).');
        }
      } else {
        setState(() => _error = 'Failed to download audio (HTTP ${getResp.statusCode}).');
      }
    } on TimeoutException catch (te) {
      setState(() => _error = 'Timeout contacting audio URL: $te');
    } on SocketException catch (se) {
      setState(() => _error = 'Network error: $se. Is server reachable from this phone?');
    } catch (e, st) {
      setState(() {
        _error = 'Audio play error: $e';
      });
      debugPrint('playback stack: $st');
    }
  }

  Widget _buildResultCard() {
    if (_original.isEmpty && _error.isEmpty) return const SizedBox.shrink();

    return AnimatedOpacity(
      opacity: 1,
      duration: const Duration(milliseconds: 400),
      child: Card(
        elevation: 5,
        margin: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_detectedScript.isNotEmpty)
              Text('Detected Script: $_detectedScript', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            if (_original.isNotEmpty) ...[
              const Text('Original Text:', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.indigo)),
              const SizedBox(height: 6),
              SelectableText(_original, style: const TextStyle(fontSize: 15, color: Colors.black87)),
              const SizedBox(height: 12),
            ],
            if (_transliterated.isNotEmpty) ...[
              const Text('Transliterated Text:', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.indigo)),
              const SizedBox(height: 6),
              SelectableText(_transliterated, style: const TextStyle(fontSize: 16, color: Colors.black87)),
              const SizedBox(height: 12),
            ],
            if (_audioUrl.isNotEmpty)
              Center(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  onPressed: _playAudio,
                  icon: const Icon(Icons.volume_up, color: Colors.white),
                  label: const Text('Play Pronunciation', style: TextStyle(color: Colors.white)),
                ),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('Error: $_error', style: const TextStyle(color: Colors.red, fontSize: 14)),
              ),
          ]),
        ),
      ),
    );
  }

  /// Open full-screen preview with Hero transition
  void _openFullPreview() {
    if (_imageFile == null) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, elevation: 0),
        body: SafeArea(
          child: Center(
            child: Hero(
              tag: 'previewImage',
              child: InteractiveViewer(
                child: Image.file(_imageFile!, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      );
    }));
  }

  @override
  Widget build(BuildContext context) {
    final gradient = const LinearGradient(
      colors: [Color(0xFF4A148C), Color(0xFF7E57C2)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Indian Script Transliterator'),
        centerTitle: true,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(gradient: gradient),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            // Image preview card — uses BoxFit.contain so entire image is visible
            GestureDetector(
              onTap: _openFullPreview,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOut,
                height: 260,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 4))],
                ),
                child: _imageFile != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Hero(
                          tag: 'previewImage',
                          child: Container(
                            color: Colors.black12,
                            padding: const EdgeInsets.all(8),
                            child: Center(
                              child: Image.file(
                                _imageFile!,
                                fit: BoxFit.contain, // <-- show entire image
                                width: double.infinity,
                              ),
                            ),
                          ),
                        ),
                      )
                    : const Center(child: Text('📸 No image selected', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500))),
              ),
            ),

            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.indigo,
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.indigo,
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo),
                  label: const Text('Gallery'),
                ),
              ),
            ]),

            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.9), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Text('🎯 Target Script:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _targetScript,
                    items: _scripts.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                    onChanged: (v) => setState(() => _targetScript = v ?? _targetScript),
                    decoration: const InputDecoration(border: InputBorder.none),
                  ),
                ),
              ]),
            ),

            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              ),
              onPressed: _loading ? null : _uploadImage,
              icon: const Icon(Icons.upload, color: Colors.white),
              label: Text(_loading ? 'Processing...' : 'Upload & Transliterate', style: const TextStyle(color: Colors.white)),
            ),

            _buildResultCard(),

            const SizedBox(height: 10),
            Text('Server: $BASE_URL', style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }
}
