import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DiceRollerApp());
}

class DiceRollerApp extends StatelessWidget {
  const DiceRollerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dice Roller',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: const DiceRollerScreen(),
      );
}

// ─── 3D Math ──────────────────────────────────────────────────────────────────

class V3 {
  final double x, y, z;
  const V3(this.x, this.y, this.z);
  V3 operator +(V3 o) => V3(x + o.x, y + o.y, z + o.z);
  V3 operator -(V3 o) => V3(x - o.x, y - o.y, z - o.z);
  V3 operator *(double s) => V3(x * s, y * s, z * s);
  double dot(V3 o) => x * o.x + y * o.y + z * o.z;
  double get len => sqrt(x * x + y * y + z * z);
  V3 get norm => this * (1.0 / len);
}

V3 rotX(V3 v, double a) => V3(v.x, v.y * cos(a) - v.z * sin(a), v.y * sin(a) + v.z * cos(a));
V3 rotY(V3 v, double a) => V3(v.x * cos(a) + v.z * sin(a), v.y, -v.x * sin(a) + v.z * cos(a));
V3 rot(V3 v, double rx, double ry) => rotY(rotX(v, rx), ry);

Offset proj(V3 v, double fov, Offset c) {
  final z = v.z + fov;
  final s = fov / z;
  return Offset(c.dx + v.x * s, c.dy + v.y * s);
}

// ─── Pip layouts (normalized -0.5..0.5) ───────────────────────────────────────

const _pips = [
  <Offset>[],
  [Offset(0, 0)],
  [Offset(-0.28, -0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0, 0), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(0, 0), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
  [Offset(-0.28, -0.28), Offset(0.28, -0.28), Offset(-0.28, 0), Offset(0.28, 0), Offset(-0.28, 0.28), Offset(0.28, 0.28)],
];

// Face order: +Z,-Z,+X,-X,+Y,-Y  →  values 1,6,2,5,3,4
const _faceVal = [1, 6, 2, 5, 3, 4];

// Target rotations to show each face value facing camera
const _targetRot = {
  1: [0.0,    0.0],
  6: [0.0,    pi],
  2: [0.0,   -pi/2],
  5: [0.0,    pi/2],
  3: [-pi/2,  0.0],
  4: [ pi/2,  0.0],
};

// ─── Die Painter ─────────────────────────────────────────────────────────────

class DiePainter extends CustomPainter {
  final double rx, ry, size;
  DiePainter({required this.rx, required this.ry, this.size = 130});

  static const double s = 0.5;
  static const _verts = [
    V3(-s,-s,-s), V3( s,-s,-s), V3( s, s,-s), V3(-s, s,-s),
    V3(-s,-s, s), V3( s,-s, s), V3( s, s, s), V3(-s, s, s),
  ];
  static const _faces = [
    [4,5,6,7], [1,0,3,2], [5,1,2,6], [0,4,7,3], [7,6,2,3], [0,1,5,4],
  ];
  static const _normals = [
    V3(0,0,1), V3(0,0,-1), V3(1,0,0), V3(-1,0,0), V3(0,1,0), V3(0,-1,0),
  ];
  static const _light = V3(0.55, -0.75, 0.55);

  @override
  void paint(Canvas canvas, Size sz) {
    final c = Offset(sz.width / 2, sz.height / 2);
    final fov = size * 2.8;
    final verts = _verts.map((v) => rot(v * size, rx, ry)).toList();
    final lightN = _light.norm;

    // Build visible faces
    final faces = <_Face>[];
    for (int i = 0; i < 6; i++) {
      final rn = rot(_normals[i], rx, ry);
      if (rn.z < 0) continue;
      final pts = _faces[i].map((idx) => proj(verts[idx], fov, c)).toList();
      final v3s = _faces[i].map((idx) => verts[idx]).toList();
      final avgZ = v3s.fold(0.0, (s, v) => s + v.z) / 4;
      final diff = max(0.0, rn.norm.dot(lightN));
      faces.add(_Face(i, _faceVal[i], pts, v3s, (0.3 + diff * 0.7).clamp(0, 1), avgZ));
    }
    faces.sort((a, b) => a.avgZ.compareTo(b.avgZ));

    for (final f in faces) {
      _drawFace(canvas, f, fov, c);
    }
  }

  void _drawFace(Canvas canvas, _Face f, double fov, Offset c) {
    final path = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
    for (int i = 1; i < f.pts.length; i++) path.lineTo(f.pts[i].dx, f.pts[i].dy);
    path.close();

    final b = f.brightness;

    // Face fill — ivory with lighting
    canvas.drawPath(path, Paint()
      ..color = Color.fromARGB(255, (238*b).round().clamp(0,255), (222*b).round().clamp(0,255), (196*b).round().clamp(0,255))
      ..style = PaintingStyle.fill);

    // Subtle gloss highlight (top-left of face)
    final gloss = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
    gloss.lineTo(f.pts[1].dx, f.pts[1].dy);
    gloss.lineTo((f.pts[1].dx + f.pts[2].dx)/2, (f.pts[1].dy + f.pts[2].dy)/2);
    gloss.lineTo((f.pts[0].dx + f.pts[3].dx)/2, (f.pts[0].dy + f.pts[3].dy)/2);
    gloss.close();
    canvas.drawPath(gloss, Paint()
      ..color = Colors.white.withOpacity(0.12 * b)
      ..style = PaintingStyle.fill);

    // Edge
    canvas.drawPath(path, Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8);

    _drawPips(canvas, f, fov, c);
  }

  void _drawPips(Canvas canvas, _Face f, double fov, Offset c) {
    final v = f.value;
    if (v < 1 || v > 6) return;

    final v0 = f.v3s[0], v1 = f.v3s[1], v3 = f.v3s[3];
    final uAxis = (v1 - v0).norm;
    final vAxis = (v3 - v0).norm;
    final fc = V3(
      f.v3s.fold(0.0, (s, v) => s + v.x) / 4,
      f.v3s.fold(0.0, (s, v) => s + v.y) / 4,
      f.v3s.fold(0.0, (s, v) => s + v.z) / 4,
    );

    final pipR3D = size * 0.068;
    final pipColor = Color.fromARGB(255, (110*f.brightness).round().clamp(0,255), (12*f.brightness).round().clamp(0,255), (12*f.brightness).round().clamp(0,255));

    for (final pip in _pips[v]) {
      final spread = size * 0.52;
      final p3D = V3(
        fc.x + uAxis.x*pip.dx*spread + vAxis.x*pip.dy*spread,
        fc.y + uAxis.y*pip.dx*spread + vAxis.y*pip.dy*spread,
        fc.z + uAxis.z*pip.dx*spread + vAxis.z*pip.dy*spread,
      );
      final p2D = proj(p3D, fov, c);
      final edge3D = V3(p3D.x + uAxis.x*pipR3D, p3D.y + uAxis.y*pipR3D, p3D.z + uAxis.z*pipR3D);
      final r2D = (proj(edge3D, fov, c) - p2D).distance.clamp(3.0, 22.0);

      // Pip shadow
      canvas.drawCircle(Offset(p2D.dx+r2D*0.15, p2D.dy+r2D*0.15), r2D, Paint()..color = Colors.black.withOpacity(0.25));
      // Pip fill
      canvas.drawCircle(p2D, r2D, Paint()..color = pipColor);
      // Pip gloss
      canvas.drawCircle(Offset(p2D.dx - r2D*0.28, p2D.dy - r2D*0.28), r2D*0.32,
          Paint()..color = Colors.white.withOpacity(0.22));
    }
  }

  @override
  bool shouldRepaint(DiePainter o) => o.rx != rx || o.ry != ry;
}

class _Face {
  final int idx, value;
  final List<Offset> pts;
  final List<V3> v3s;
  final double brightness, avgZ;
  _Face(this.idx, this.value, this.pts, this.v3s, this.brightness, this.avgZ);
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class DiceRollerScreen extends StatefulWidget {
  const DiceRollerScreen({super.key});
  @override
  State<DiceRollerScreen> createState() => _DiceRollerScreenState();
}

class _DiceRollerScreenState extends State<DiceRollerScreen> with TickerProviderStateMixin {
  int _numDice = 1;
  List<int> _results = [1];
  bool _rolling = false;
  final _rand = Random();

  List<double> _rx = [0.4];
  List<double> _ry = [0.6];
  List<AnimationController> _ctrls = [];
  List<Animation<double>> _rxAnims = [];
  List<Animation<double>> _ryAnims = [];

  @override
  void initState() {
    super.initState();
    _initDice(1);
  }

  void _initDice(int n) {
    for (final c in _ctrls) c.dispose();
    _rx = List.filled(n, 0.4);
    _ry = List.filled(n, 0.6);
    _results = List.filled(n, 1);
    _ctrls = List.generate(n, (_) => AnimationController(vsync: this, duration: const Duration(milliseconds: 1800)));
    _rxAnims = List.filled(n, const AlwaysStoppedAnimation(0));
    _ryAnims = List.filled(n, const AlwaysStoppedAnimation(0));
  }

  @override
  void dispose() {
    for (final c in _ctrls) c.dispose();
    super.dispose();
  }

  Future<void> _roll() async {
    if (_rolling) return;
    setState(() => _rolling = true);
    HapticFeedback.mediumImpact();

    final newResults = List.generate(_numDice, (_) => _rand.nextInt(6) + 1);

    final futures = <Future>[];
    for (int i = 0; i < _numDice; i++) {
      final tgt = _targetRot[newResults[i]]!;
      final sRx = _rx[i], sRy = _ry[i];
      final eRx = sRx + pi * (4 + _rand.nextInt(3)) + tgt[0];
      final eRy = sRy + pi * (4 + _rand.nextInt(3)) + tgt[1];

      _ctrls[i].reset();
      _rxAnims[i] = Tween(begin: sRx, end: eRx)
          .animate(CurvedAnimation(parent: _ctrls[i], curve: Curves.easeInOutCubic));
      _ryAnims[i] = Tween(begin: sRy, end: eRy)
          .animate(CurvedAnimation(parent: _ctrls[i], curve: Curves.easeInOutCubic));

      _ctrls[i].addListener(() => setState(() {
        _rx[i] = _rxAnims[i].value;
        _ry[i] = _ryAnims[i].value;
      }));

      futures.add(Future.delayed(Duration(milliseconds: i * 120), () => _ctrls[i].forward()));
    }

    await Future.wait(futures);
    await Future.delayed(Duration(milliseconds: 1800 + (_numDice - 1) * 120));

    if (mounted) setState(() { _results = newResults; _rolling = false; });
    HapticFeedback.lightImpact();
  }

  void _setNum(int n) {
    if (_rolling || n < 1 || n > 5) return;
    setState(() { _numDice = n; _initDice(n); });
  }

  List<Offset> _positions(int n) => switch (n) {
    1 => [Offset.zero],
    2 => [const Offset(-0.28, 0), const Offset(0.28, 0)],
    3 => [const Offset(-0.38, -0.15), const Offset(0, 0.15), const Offset(0.38, -0.15)],
    4 => [const Offset(-0.28, -0.2), const Offset(0.28, -0.2), const Offset(-0.28, 0.2), const Offset(0.28, 0.2)],
    5 => [const Offset(-0.38, -0.2), const Offset(0, -0.2), const Offset(0.38, -0.2), const Offset(-0.19, 0.2), const Offset(0.19, 0.2)],
    _ => [Offset.zero],
  };

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final dieSize = _numDice == 1 ? sw * 0.36 : (_numDice <= 2 ? sw * 0.26 : sw * 0.20);
    final sum = _results.fold(0, (a, b) => a + b);
    final pos = _positions(_numDice);

    return Scaffold(
      backgroundColor: const Color(0xFF0A1A10),
      body: SafeArea(
        child: Column(children: [
          // Header
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('🎲  DICE ROLLER', style: TextStyle(
              color: Color(0xFFD4AF37), fontSize: 20,
              fontWeight: FontWeight.bold, letterSpacing: 4,
            )),
          ),

          // Count selector
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _iconBtn(Icons.remove, () => _setNum(_numDice - 1), _numDice > 1 && !_rolling),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('$_numDice ${_numDice == 1 ? 'die' : 'dice'}',
                  style: const TextStyle(color: Colors.white70, fontSize: 15, letterSpacing: 1)),
            ),
            _iconBtn(Icons.add, () => _setNum(_numDice + 1), _numDice < 5 && !_rolling),
          ]),

          const SizedBox(height: 8),

          // Dice area
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: List.generate(_numDice, (i) {
                final p = pos[i];
                return Positioned(
                  left: sw/2 + p.dx * sw - dieSize/2,
                  top: sh * 0.18 + p.dy * sh * 0.3 - dieSize/2,
                  child: GestureDetector(
                    onPanUpdate: (d) {
                      if (_rolling) return;
                      setState(() {
                        _ry[i] += d.delta.dx * 0.009;
                        _rx[i] += d.delta.dy * 0.009;
                      });
                    },
                    child: CustomPaint(
                      size: Size(dieSize * 2, dieSize * 2),
                      painter: DiePainter(rx: _rx[i], ry: _ry[i], size: dieSize),
                    ),
                  ),
                );
              }),
            ),
          ),

          // Result
          AnimatedOpacity(
            opacity: _rolling ? 0.2 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                if (_numDice > 1)
                  Text(_results.join('  +  '), style: const TextStyle(color: Colors.white54, fontSize: 14)),
                Text(
                  _numDice > 1 ? 'Sum: $sum' : '${_results[0]}',
                  style: TextStyle(
                    color: const Color(0xFFD4AF37),
                    fontSize: _numDice > 1 ? 26 : 56,
                    fontWeight: FontWeight.bold,
                    shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
                  ),
                ),
              ]),
            ),
          ),

          // Roll button
          Padding(
            padding: const EdgeInsets.only(bottom: 28, top: 4),
            child: GestureDetector(
              onTap: _roll,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 52, vertical: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: _rolling
                      ? [const Color(0xFF5A4A10), const Color(0xFF3A300A)]
                      : [const Color(0xFFD4AF37), const Color(0xFF9B7B1A)]),
                  borderRadius: BorderRadius.circular(40),
                  boxShadow: _rolling ? [] : [
                    BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.45), blurRadius: 20, spreadRadius: 2)
                  ],
                ),
                child: Text(
                  _rolling ? 'ROLLING...' : 'R O L L',
                  style: const TextStyle(color: Colors.black, fontSize: 17, fontWeight: FontWeight.bold, letterSpacing: 3),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback cb, bool enabled) => GestureDetector(
    onTap: enabled ? cb : null,
    child: Container(
      width: 34, height: 34,
      decoration: BoxDecoration(
        color: enabled ? const Color(0xFFD4AF37).withOpacity(0.15) : Colors.white10,
        shape: BoxShape.circle,
        border: Border.all(color: enabled ? const Color(0xFFD4AF37).withOpacity(0.4) : Colors.white12),
      ),
      child: Icon(icon, color: enabled ? const Color(0xFFD4AF37) : Colors.white24, size: 17),
    ),
  );
}
