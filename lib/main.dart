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

// Generate a die face texture for a given value
Future<three.Texture> _makeFaceTexture(int value) async {
  const int size = 256;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()));

  // Background: ivory/cream
  final bgPaint = Paint()..color = const Color(0xFFF5ECD7);
  final rrect = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    const Radius.circular(36),
  );
  canvas.drawRRect(rrect, bgPaint);

  // Border shadow effect
  final borderPaint = Paint()
    ..color = const Color(0xFFD4C4A0)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 6;
  canvas.drawRRect(rrect, borderPaint);

  // Pips
  final pipPaint = Paint()..color = const Color(0xFF8B1A1A);
  final pips = _pipLayouts[value];
  const double cx = size / 2;
  const double cy = size / 2;
  const double spread = 76.0;
  const double pipR = 18.0;

  for (final pip in pips) {
    final x = cx + pip.dx * spread;
    final y = cy + pip.dy * spread;
    canvas.drawCircle(Offset(x, y), pipR, pipPaint);
    // Highlight on pip
    canvas.drawCircle(
      Offset(x - pipR * 0.25, y - pipR * 0.25),
      pipR * 0.35,
      Paint()..color = Colors.white.withOpacity(0.3),
    );
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(size, size);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = byteData!.buffer.asUint8List();

  final texData = Uint8List(bytes.length)..setAll(0, bytes);
  final tex = three.DataTexture(
    texData,
    size,
    size,
    three.RGBAFormat,
  );
  tex.needsUpdate = true;
  return tex;
}

// Face order for BoxGeometry in three_dart: +X, -X, +Y, -Y, +Z, -Z
// Standard die: opposite faces sum to 7
// Right(+X)=2, Left(-X)=5, Top(+Y)=1, Bottom(-Y)=6, Front(+Z)=3, Back(-Z)=4
const List<int> _faceValues = [2, 5, 1, 6, 3, 4];

// Target Euler rotation (x, y) so face N faces the camera (+Z)
const Map<int, List<double>> _targetRotations = {
  3: [0,           0],           // front +Z
  4: [0,           pi],         // back -Z
  2: [0,          -pi / 2],     // right +X
  5: [0,           pi / 2],     // left -X
  1: [-pi / 2,     0],          // top +Y
  6: [ pi / 2,     0],          // bottom -Y
};

// ─── Main Screen ──────────────────────────────────────────────────────────────

class DiceRollerScreen extends StatefulWidget {
  const DiceRollerScreen({super.key});

  @override
  State<DiceRollerScreen> createState() => _DiceRollerScreenState();
}

class _DiceRollerScreenState extends State<DiceRollerScreen> with TickerProviderStateMixin {
  // three_dart
  late FlutterGlPlugin _glPlugin;
  three.WebGLRenderer? _renderer;
  three.WebGLMultisampleRenderTarget? _renderTarget;
  dynamic _sourceTexture;

  late three.Scene _scene;
  late three.PerspectiveCamera _camera;
  late three.Mesh _diceMesh;
  late three.AmbientLight _ambient;
  late three.DirectionalLight _dirLight;

  Size? _screenSize;
  double _dpr = 1.0;
  bool _glReady = false;
  bool _loaded = false;

  // Animation
  late AnimationController _rollController;
  late AnimationController _renderController;

  double _rotX = 0.3;
  double _rotY = 0.5;
  double _rotZ = 0.0;

  double _startRx = 0, _startRy = 0;
  double _endRx = 0, _endRy = 0;

  int _result = 1;
  bool _rolling = false;
  int _numDice = 1;
  List<int> _results = [1];

  // Per-die meshes for multi-dice
  final List<three.Mesh> _diceMeshes = [];
  final List<double> _diceRx = [];
  final List<double> _diceRy = [];
  List<AnimationController> _diceControllers = [];

  final _rand = Random();
  List<three.Material>? _diceMaterials;

  @override
  void initState() {
    super.initState();

    _rollController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    _renderController = AnimationController(vsync: this, duration: const Duration(days: 1))
      ..repeat();

    _rollController.addListener(_onRollTick);
    _renderController.addListener(_renderFrame);
  }

  Future<void> _initPlatform() async {
    final w = _screenSize!.width;
    final h = _screenSize!.height * 0.55;

    _glPlugin = FlutterGlPlugin();
    await _glPlugin.initialize(options: {
      "antialias": true,
      "alpha": false,
      "width": w.toInt(),
      "height": h.toInt(),
      "dpr": _dpr,
    });

    setState(() => _glReady = true);

    await Future.delayed(const Duration(milliseconds: 200));
    await _glPlugin.prepareContext();

    await _initScene();
  }

  Future<void> _initScene() async {
    final w = _screenSize!.width;
    final h = _screenSize!.height * 0.55;

    // Renderer
    _renderer = three.WebGLRenderer({
      "width": w,
      "height": h,
      "gl": _glPlugin.gl,
      "antialias": true,
      "canvas": _glPlugin.element,
    });
    _renderer!.setPixelRatio(_dpr);
    _renderer!.setSize(w, h, false);
    _renderer!.shadowMap.enabled = true;
    _renderer!.shadowMap.type = three.PCFSoftShadowMap;

    var pars = three.WebGLRenderTargetOptions({"format": three.RGBAFormat});
    _renderTarget = three.WebGLMultisampleRenderTarget((w * _dpr).toInt(), (h * _dpr).toInt(), pars);
    _renderTarget!.samples = 4;
    _renderer!.setRenderTarget(_renderTarget);
    _sourceTexture = _renderer!.getRenderTargetGLTexture(_renderTarget!);

    // Scene
    _scene = three.Scene();
    _scene.background = three.Color(0x0F2318);

    // Camera
    _camera = three.PerspectiveCamera(50, w / h, 0.1, 1000);
    _camera.position.set(0, 0, 4.5);

    // Lights
    _ambient = three.AmbientLight(0xffffff, 0.5);
    _scene.add(_ambient);

    _dirLight = three.DirectionalLight(0xffffff, 1.0);
    _dirLight.position.set(5, 8, 5);
    _dirLight.castShadow = true;
    _scene.add(_dirLight);

    final fillLight = three.DirectionalLight(0xffd0a0, 0.3);
    fillLight.position.set(-5, -3, 3);
    _scene.add(fillLight);

    // Build die face textures
    final textures = await Future.wait(
      List.generate(6, (i) => _makeFaceTexture(_faceValues[i])),
    );

    _diceMaterials = textures.map((tex) => three.MeshPhongMaterial({
      "map": tex,
      "shininess": 60,
      "specular": three.Color(0x444444),
    })).toList();

    // Create initial single die
    await _rebuildDice(_numDice);

    setState(() => _loaded = true);
  }

  Future<void> _rebuildDice(int count) async {
    // Remove old meshes
    for (final m in _diceMeshes) _scene.remove(m);
    _diceMeshes.clear();
    _diceRx.clear();
    _diceRy.clear();
    for (final c in _diceControllers) c.dispose();
    _diceControllers = [];

    final geo = three.BoxGeometry(1.8, 1.8, 1.8);

    // Positions for multiple dice
    final positions = _dicePositions(count);

    for (int i = 0; i < count; i++) {
      final mesh = three.Mesh(geo, _diceMaterials);
      mesh.position.set(positions[i].dx, positions[i].dy, 0);
      mesh.castShadow = true;
      mesh.receiveShadow = false;
      _scene.add(mesh);
      _diceMeshes.add(mesh);
      _diceRx.add(0.3);
      _diceRy.add(0.5);

      final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
      _diceControllers.add(ctrl);
    }

    _results = List.filled(count, 1);
  }

  List<Offset> _dicePositions(int count) {
    switch (count) {
      case 1: return [Offset.zero];
      case 2: return [const Offset(-1.3, 0), const Offset(1.3, 0)];
      case 3: return [const Offset(-2.2, 0.6), const Offset(0, -0.6), const Offset(2.2, 0.6)];
      case 4: return [const Offset(-1.5, 0.8), const Offset(1.5, 0.8), const Offset(-1.5, -0.8), const Offset(1.5, -0.8)];
      case 5: return [const Offset(-2.5, 0.9), const Offset(0, 0.9), const Offset(2.5, 0.9), const Offset(-1.3, -0.9), const Offset(1.3, -0.9)];
      default: return [Offset.zero];
    }
  }

  void _onRollTick() {
    // Handled per-die in roll()
  }

  void _renderFrame() {
    if (!_loaded || _renderer == null) return;

    // Update mesh rotations
    for (int i = 0; i < _diceMeshes.length; i++) {
      _diceMeshes[i].rotation.x = _diceRx[i];
      _diceMeshes[i].rotation.y = _diceRy[i];
    }

    _renderer!.render(_scene, _camera);
    _glPlugin.gl.flush();
    _glPlugin.updateTexture(_sourceTexture);
  }

  Future<void> _roll() async {
    if (_rolling) return;
    setState(() => _rolling = true);
    HapticFeedback.mediumImpact();

    final newResults = List.generate(_numDice, (_) => _rand.nextInt(6) + 1);

    final futures = <Future>[];
    for (int i = 0; i < _numDice; i++) {
      final target = _targetRotations[newResults[i]]!;
      final startRx = _diceRx[i];
      final startRy = _diceRy[i];
      final endRx = startRx + pi * (4 + _rand.nextInt(3).toDouble()) + target[0];
      final endRy = startRy + pi * (4 + _rand.nextInt(3).toDouble()) + target[1];

      final ctrl = _diceControllers[i];
      ctrl.reset();

      final rxAnim = Tween(begin: startRx, end: endRx)
          .animate(CurvedAnimation(parent: ctrl, curve: Curves.easeInOutCubic));
      final ryAnim = Tween(begin: startRy, end: endRy)
          .animate(CurvedAnimation(parent: ctrl, curve: Curves.easeInOutCubic));

      void listener() {
        _diceRx[i] = rxAnim.value;
        _diceRy[i] = ryAnim.value;
      }

      ctrl.addListener(listener);

      final delay = Duration(milliseconds: i * 100);
      futures.add(Future.delayed(delay, () => ctrl.forward()));
    }

    await Future.wait(futures);
    await Future.delayed(Duration(milliseconds: 1800 + (_numDice - 1) * 100));

    setState(() {
      _results = newResults;
      _rolling = false;
    });
    HapticFeedback.lightImpact();
  }

  void _onPanUpdate(DragUpdateDetails d, int index) {
    if (_rolling) return;
    setState(() {
      _diceRy[index] += d.delta.dx * 0.008;
      _diceRx[index] += d.delta.dy * 0.008;
    });
  }

  void _setNumDice(int n) {
    if (_rolling || n < 1 || n > 5) return;
    setState(() => _numDice = n);
    _rebuildDice(n);
  }

  @override
  void dispose() {
    _rollController.dispose();
    _renderController.dispose();
    for (final c in _diceControllers) c.dispose();
    super.dispose();
  }

  void _initSize(BuildContext context) {
    if (_screenSize != null) return;
    final mqd = MediaQuery.of(context);
    _screenSize = mqd.size;
    _dpr = mqd.devicePixelRatio;
    _initPlatform();
  }

  @override
  Widget build(BuildContext context) {
    _initSize(context);
    final w = _screenSize?.width ?? 400;
    final h = (_screenSize?.height ?? 700) * 0.55;
    final sum = _results.fold(0, (a, b) => a + b);

    return Scaffold(
      backgroundColor: const Color(0xFF0F2318),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('🎲  DICE ROLLER',
                  style: TextStyle(
                    color: const Color(0xFFD4AF37),
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                  )),
            ),

            // Dice count
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _btn(Icons.remove, () => _setNumDice(_numDice - 1), _numDice > 1 && !_rolling),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text('$_numDice ${_numDice == 1 ? 'die' : 'dice'}',
                      style: const TextStyle(color: Colors.white70, fontSize: 15, letterSpacing: 1)),
                ),
                _btn(Icons.add, () => _setNumDice(_numDice + 1), _numDice < 5 && !_rolling),
              ],
            ),

            const SizedBox(height: 10),

            // 3D Canvas
            GestureDetector(
              onPanUpdate: (d) => _onPanUpdate(d, 0),
              child: Container(
                width: w,
                height: h,
                color: Colors.transparent,
                child: Builder(builder: (ctx) {
                  if (!_glReady) {
                    return const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)));
                  }
                  if (kIsWeb) {
                    return _glPlugin.isInitialized
                        ? HtmlElementView(viewType: _glPlugin.textureId!.toString())
                        : Container();
                  } else {
                    return _glPlugin.isInitialized
                        ? Texture(textureId: _glPlugin.textureId!)
                        : Container();
                  }
                }),
              ),
            ),

            // Result display
            AnimatedOpacity(
              opacity: _rolling ? 0.3 : 1.0,
              duration: const Duration(milliseconds: 300),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  children: [
                    if (_numDice > 1)
                      Text(_results.join('  +  '),
                          style: const TextStyle(color: Colors.white54, fontSize: 15)),
                    Text(
                      _numDice > 1 ? 'Sum: $sum' : '${_results[0]}',
                      style: TextStyle(
                        color: const Color(0xFFD4AF37),
                        fontSize: _numDice > 1 ? 26 : 52,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Roll button
            Padding(
              padding: const EdgeInsets.only(bottom: 24, top: 4),
              child: GestureDetector(
                onTap: _roll,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _rolling
                          ? [const Color(0xFF5A4A10), const Color(0xFF3A300A)]
                          : [const Color(0xFFD4AF37), const Color(0xFF9B7B1A)],
                    ),
                    borderRadius: BorderRadius.circular(40),
                    boxShadow: _rolling
                        ? []
                        : [BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.4), blurRadius: 18, spreadRadius: 2)],
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

  Widget _btn(IconData icon, VoidCallback cb, bool enabled) {
    return GestureDetector(
      onTap: enabled ? cb : null,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFD4AF37).withOpacity(0.15) : Colors.white10,
          shape: BoxShape.circle,
          border: Border.all(color: enabled ? const Color(0xFFD4AF37).withOpacity(0.4) : Colors.white12),
        ),
        child: Icon(icon, color: enabled ? const Color(0xFFD4AF37) : Colors.white24, size: 17),
      ),
    );
  }
}
