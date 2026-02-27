import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gl/flutter_gl.dart';
import 'package:three_dart/three_dart.dart' as three;
import 'package:three_dart/three3d/objects/index.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DiceRollerApp());
}

class DiceRollerApp extends StatelessWidget {
  const DiceRollerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dice Roller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const DiceRollerScreen(),
    );
  }
}

// ─── Pip layout per face value ────────────────────────────────────────────────
const List<List<Offset>> _pipLayouts = [
  [],
  [Offset(0, 0)],
  [Offset(-0.28, -0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0, 0), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(0, 0), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(-0.28, 0), Offset(0.28, 0), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
];

// Face order for BoxGeometry in three_dart: +X,-X,+Y,-Y,+Z,-Z
const List<int> _faceValues = [2, 5, 1, 6, 3, 4];

// Target euler (rx, ry) so face value N faces camera (+Z)
const Map<int, List<double>> _targetRot = {
  3: [0,          0],
  4: [0,          pi],
  2: [0,         -pi / 2],
  5: [0,          pi / 2],
  1: [-pi / 2,    0],
  6: [ pi / 2,    0],
};

Future<three.DataTexture> _makeFaceTexture(int value) async {
  const int sz = 256;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, sz.toDouble(), sz.toDouble()));

  // Ivory background with rounded rect
  final rr = RRect.fromRectAndRadius(const Rect.fromLTWH(4, 4, 248, 248), const Radius.circular(38));
  canvas.drawRRect(rr, Paint()..color = const Color(0xFFF5ECD7));
  canvas.drawRRect(rr, Paint()..color = const Color(0xFFD4C0A0)..style = PaintingStyle.stroke..strokeWidth = 5);

  // Pips
  final pipPaint = Paint()..color = const Color(0xFF7A1515);
  for (final pip in _pipLayouts[value]) {
    final x = 128 + pip.dx * 80.0;
    final y = 128 + pip.dy * 80.0;
    canvas.drawCircle(Offset(x, y), 19, pipPaint);
    canvas.drawCircle(Offset(x - 5, y - 5), 6, Paint()..color = Colors.white.withOpacity(0.25));
  }

  final pic = rec.endRecording();
  final img = await pic.toImage(sz, sz);
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = Uint8List.fromList(bd!.buffer.asUint8List());

  final tex = three.DataTexture(bytes, sz, sz, three.RGBAFormat);
  tex.needsUpdate = true;
  return tex;
}

// ─── Main Screen ──────────────────────────────────────────────────────────────
class DiceRollerScreen extends StatefulWidget {
  const DiceRollerScreen({super.key});
  @override
  State<DiceRollerScreen> createState() => _DiceRollerScreenState();
}

class _DiceRollerScreenState extends State<DiceRollerScreen> with TickerProviderStateMixin {
  // GL / three_dart
  late FlutterGlPlugin _gl;
  three.WebGLRenderer? _renderer;
  three.WebGLMultisampleRenderTarget? _rt;
  dynamic _srcTex;

  late three.Scene _scene;
  late three.PerspectiveCamera _camera;

  Size? _size;
  double _dpr = 1.0;
  bool _glReady = false;
  bool _loaded = false;
  bool _disposed = false;

  // Dice state
  int _numDice = 1;
  List<int> _results = [1];
  bool _rolling = false;
  final _rand = Random();

  final List<three.Mesh> _meshes = [];
  final List<double> _rx = [];
  final List<double> _ry = [];

  // Roll animation
  List<AnimationController> _rollCtrls = [];
  List<Animation<double>> _rxAnims = [];
  List<Animation<double>> _ryAnims = [];

  List<three.Material>? _mats;

  @override
  void initState() {
    super.initState();
  }

  void _initSize(BuildContext ctx) {
    if (_size != null) return;
    final mq = MediaQuery.of(ctx);
    _size = mq.size;
    _dpr = mq.devicePixelRatio;
    _initPlatform();
  }

  Future<void> _initPlatform() async {
    final w = _size!.width;
    final h = _size!.height * 0.56;

    _gl = FlutterGlPlugin();
    await _gl.initialize(options: {
      "antialias": true,
      "alpha": false,
      "width": w.toInt(),
      "height": h.toInt(),
      "dpr": _dpr,
    });

    setState(() => _glReady = true);

    await Future.delayed(const Duration(milliseconds: 200));
    await _gl.prepareContext();
    await _initScene(w, h);
  }

  Future<void> _initScene(double w, double h) async {
    // Renderer
    _renderer = three.WebGLRenderer({
      "width": w,
      "height": h,
      "gl": _gl.gl,
      "antialias": true,
      "canvas": _gl.element,
    });
    _renderer!.setPixelRatio(_dpr);
    _renderer!.setSize(w, h, false);
    _renderer!.shadowMap.enabled = true;
    _renderer!.shadowMap.type = three.PCFSoftShadowMap;

    final pars = three.WebGLRenderTargetOptions({"format": three.RGBAFormat});
    _rt = three.WebGLMultisampleRenderTarget((w * _dpr).toInt(), (h * _dpr).toInt(), pars);
    _rt!.samples = 4;
    _renderer!.setRenderTarget(_rt);
    _srcTex = _renderer!.getRenderTargetGLTexture(_rt!);

    // Scene & camera
    _scene = three.Scene();
    _scene.background = three.Color(0x0F2318);

    _camera = three.PerspectiveCamera(50, w / h, 0.1, 100);
    _camera.position.set(0, 0, 5);
    _camera.lookAt(three.Vector3(0, 0, 0));

    // Lights
    _scene.add(three.AmbientLight(0xffffff, 0.55));

    final dir = three.DirectionalLight(0xfff5e0, 1.2);
    dir.position.set(4, 6, 5);
    dir.castShadow = true;
    _scene.add(dir);

    final fill = three.DirectionalLight(0x8090ff, 0.25);
    fill.position.set(-4, -2, 3);
    _scene.add(fill);

    // Build face materials
    final textures = await Future.wait(
      List.generate(6, (i) => _makeFaceTexture(_faceValues[i])),
    );
    _mats = textures.map((t) => three.MeshPhongMaterial({
      "map": t,
      "shininess": 80,
      "specular": three.Color(0x888888),
    })).toList();

    await _buildDice(_numDice);

    setState(() => _loaded = true);
    _animate();
  }

  Future<void> _buildDice(int count) async {
    for (final m in _meshes) _scene.remove(m);
    _meshes.clear();
    _rx.clear();
    _ry.clear();
    for (final c in _rollCtrls) c.dispose();
    _rollCtrls = [];
    _rxAnims = [];
    _ryAnims = [];

    final geo = three.BoxGeometry(1.8, 1.8, 1.8);
    final positions = _positions(count);

    for (int i = 0; i < count; i++) {
      final mesh = three.Mesh(geo, _mats);
      mesh.position.set(positions[i].dx, positions[i].dy, 0);
      mesh.castShadow = true;
      _scene.add(mesh);
      _meshes.add(mesh);
      _rx.add(0.4);
      _ry.add(0.6);

      final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
      _rollCtrls.add(ctrl);
      _rxAnims.add(const AlwaysStoppedAnimation(0));
      _ryAnims.add(const AlwaysStoppedAnimation(0));
    }
    _results = List.filled(count, 1);
  }

  List<Offset> _positions(int n) => switch (n) {
    1 => [Offset.zero],
    2 => [const Offset(-1.2, 0), const Offset(1.2, 0)],
    3 => [const Offset(-2.1, 0.5), const Offset(0, -0.5), const Offset(2.1, 0.5)],
    4 => [const Offset(-1.3, 0.8), const Offset(1.3, 0.8), const Offset(-1.3, -0.8), const Offset(1.3, -0.8)],
    5 => [const Offset(-2.4, 0.8), const Offset(0, 0.8), const Offset(2.4, 0.8), const Offset(-1.2, -0.8), const Offset(1.2, -0.8)],
    _ => [Offset.zero],
  };

  void _animate() {
    if (_disposed || !_loaded) return;

    // Update mesh rotations from current state
    for (int i = 0; i < _meshes.length; i++) {
      _meshes[i].rotation.x = _rx[i];
      _meshes[i].rotation.y = _ry[i];
    }

    _renderer?.render(_scene, _camera);
    _gl.gl.flush();
    if (!kIsWeb) _gl.updateTexture(_srcTex);

    Future.delayed(const Duration(milliseconds: 16), _animate); // ~60fps
  }

  Future<void> _roll() async {
    if (_rolling || !_loaded) return;
    setState(() => _rolling = true);
    HapticFeedback.mediumImpact();

    final newResults = List.generate(_numDice, (_) => _rand.nextInt(6) + 1);
    final futures = <Future>[];

    for (int i = 0; i < _numDice; i++) {
      final tgt = _targetRot[newResults[i]]!;
      final sRx = _rx[i], sRy = _ry[i];
      final eRx = sRx + pi * (4 + _rand.nextInt(3)) + tgt[0];
      final eRy = sRy + pi * (4 + _rand.nextInt(3)) + tgt[1];

      _rollCtrls[i].reset();
      _rxAnims[i] = Tween(begin: sRx, end: eRx)
          .animate(CurvedAnimation(parent: _rollCtrls[i], curve: Curves.easeInOutCubic));
      _ryAnims[i] = Tween(begin: sRy, end: eRy)
          .animate(CurvedAnimation(parent: _rollCtrls[i], curve: Curves.easeInOutCubic));

      _rollCtrls[i].addListener(() {
        _rx[i] = _rxAnims[i].value;
        _ry[i] = _ryAnims[i].value;
      });

      futures.add(
        Future.delayed(Duration(milliseconds: i * 120), () => _rollCtrls[i].forward()),
      );
    }

    await Future.wait(futures);
    await Future.delayed(Duration(milliseconds: 1800 + (_numDice - 1) * 120));

    if (mounted) {
      setState(() {
        _results = newResults;
        _rolling = false;
      });
    }
    HapticFeedback.lightImpact();
  }

  void _setNum(int n) {
    if (_rolling || n < 1 || n > 5 || !_loaded) return;
    setState(() => _numDice = n);
    _buildDice(n);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _rollCtrls) c.dispose();
    _gl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _initSize(context);
    final w = _size?.width ?? 400;
    final glH = (_size?.height ?? 700) * 0.56;
    final sum = _results.fold(0, (a, b) => a + b);

    return Scaffold(
      backgroundColor: const Color(0xFF0F2318),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('🎲  DICE ROLLER',
                  style: TextStyle(
                    color: Color(0xFFD4AF37),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  )),
            ),

            // Count selector
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _iconBtn(Icons.remove, () => _setNum(_numDice - 1), _numDice > 1 && !_rolling),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('$_numDice ${_numDice == 1 ? 'die' : 'dice'}',
                      style: const TextStyle(color: Colors.white70, fontSize: 15, letterSpacing: 1)),
                ),
                _iconBtn(Icons.add, () => _setNum(_numDice + 1), _numDice < 5 && !_rolling),
              ],
            ),

            const SizedBox(height: 8),

            // 3D Canvas — drag to rotate first die
            GestureDetector(
              onPanUpdate: (d) {
                if (_rolling || _meshes.isEmpty) return;
                _ry[0] += d.delta.dx * 0.009;
                _rx[0] += d.delta.dy * 0.009;
              },
              child: Container(
                width: w,
                height: glH,
                color: Colors.transparent,
                child: Builder(builder: (ctx) {
                  if (!_glReady) {
                    return const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(color: Color(0xFFD4AF37)),
                          SizedBox(height: 12),
                          Text('Loading 3D engine...', style: TextStyle(color: Colors.white54)),
                        ],
                      ),
                    );
                  }
                  if (kIsWeb) {
                    return _gl.isInitialized
                        ? HtmlElementView(viewType: _gl.textureId!.toString())
                        : Container();
                  }
                  return _gl.isInitialized
                      ? Texture(textureId: _gl.textureId!)
                      : Container();
                }),
              ),
            ),

            // Result
            AnimatedOpacity(
              opacity: _rolling ? 0.25 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    if (_numDice > 1)
                      Text(_results.join('  +  '),
                          style: const TextStyle(color: Colors.white54, fontSize: 14)),
                    Text(
                      _numDice > 1 ? 'Sum: $sum' : '${_results[0]}',
                      style: TextStyle(
                        color: const Color(0xFFD4AF37),
                        fontSize: _numDice > 1 ? 24 : 50,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Roll button
            Padding(
              padding: const EdgeInsets.only(bottom: 20, top: 4),
              child: GestureDetector(
                onTap: _roll,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 15),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _rolling
                          ? [const Color(0xFF5A4A10), const Color(0xFF3A300A)]
                          : [const Color(0xFFD4AF37), const Color(0xFF9B7B1A)],
                    ),
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: _rolling
                        ? []
                        : [BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.45), blurRadius: 18, spreadRadius: 2)],
                  ),
                  child: Text(
                    _rolling ? 'ROLLING...' : 'R O L L',
                    style: const TextStyle(
                        color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback cb, bool enabled) {
    return GestureDetector(
      onTap: enabled ? cb : null,
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFD4AF37).withOpacity(0.15) : Colors.white10,
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? const Color(0xFFD4AF37).withOpacity(0.4) : Colors.white12,
          ),
        ),
        child: Icon(icon, color: enabled ? const Color(0xFFD4AF37) : Colors.white24, size: 17),
      ),
    );
  }
}
