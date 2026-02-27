import 'dart:math';
import 'dart:ui' as ui;
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
V3 applyRot(V3 v, double rx, double ry) => rotY(rotX(v, rx), ry);

Offset project(V3 v, double fov, Offset center) {
  final z = v.z + fov;
  final s = fov / z;
  return Offset(center.dx + v.x * s, center.dy + v.y * s);
}

// ─── Pip layouts ──────────────────────────────────────────────────────────────

const _pips = [
  <Offset>[],
  [Offset(0, 0)],
  [Offset(-0.3, -0.3), Offset(0.3, 0.3)],
  [Offset(-0.3, -0.3), Offset(0, 0), Offset(0.3, 0.3)],
  [Offset(-0.3, -0.3), Offset(0.3, -0.3), Offset(-0.3, 0.3), Offset(0.3, 0.3)],
  [Offset(-0.3, -0.3), Offset(0.3, -0.3), Offset(0, 0), Offset(-0.3, 0.3), Offset(0.3, 0.3)],
  [Offset(-0.3, -0.3), Offset(0.3, -0.3), Offset(-0.3, 0), Offset(0.3, 0), Offset(-0.3, 0.3), Offset(0.3, 0.3)],
];

// Face order: +Z,-Z,+X,-X,+Y,-Y → values 1,6,2,5,3,4
const _faceValues = [1, 6, 2, 5, 3, 4];

const _targetRot = {
  1: [0.0,    0.0],
  6: [0.0,    pi],
  2: [0.0,   -pi / 2],
  5: [0.0,    pi / 2],
  3: [-pi / 2, 0.0],
  4: [pi / 2,  0.0],
};

// ─── Die Painter ─────────────────────────────────────────────────────────────

class DiePainter extends CustomPainter {
  final double rx, ry, dieSize;
  DiePainter({required this.rx, required this.ry, required this.dieSize});

  static const double _s = 0.5;
  static const _verts = [
    V3(-_s,-_s,-_s), V3(_s,-_s,-_s), V3(_s,_s,-_s), V3(-_s,_s,-_s),
    V3(-_s,-_s,_s),  V3(_s,-_s,_s),  V3(_s,_s,_s),  V3(-_s,_s,_s),
  ];
  static const _faceIdx = [
    [4,5,6,7], [1,0,3,2], [5,1,2,6], [0,4,7,3], [7,6,2,3], [0,1,5,4],
  ];
  static const _normals = [
    V3(0,0,1), V3(0,0,-1), V3(1,0,0), V3(-1,0,0), V3(0,1,0), V3(0,-1,0),
  ];
  // Key light from upper-left-front
  static const _light    = V3(-0.4, -0.8, 0.6);
  // Fill light from lower-right
  static const _fillLight = V3(0.6,  0.4, 0.4);

  @override
  void paint(Canvas canvas, Size sz) {
    final c   = Offset(sz.width / 2, sz.height / 2);
    final fov = dieSize * 2.6;
    final verts = _verts.map((v) => applyRot(v * dieSize, rx, ry)).toList();
    final lightN = _light.norm;
    final fillN  = _fillLight.norm;

    // Gather visible faces + depth sort
    final faces = <_FaceData>[];
    for (int i = 0; i < 6; i++) {
      final rn = applyRot(_normals[i], rx, ry);
      if (rn.z < 0) continue;
      final idxList = _faceIdx[i];
      final pts  = idxList.map((j) => project(verts[j], fov, c)).toList();
      final v3s  = idxList.map((j) => verts[j]).toList();
      final avgZ = v3s.fold(0.0, (s, v) => s + v.z) / 4;
      final rnN  = rn.norm;
      final diff  = max(0.0, rnN.dot(lightN));
      final fill  = max(0.0, rnN.dot(fillN)) * 0.25;
      final bright = (0.22 + diff * 0.6 + fill).clamp(0.0, 1.0);
      faces.add(_FaceData(i, _faceValues[i], pts, v3s, bright, avgZ, rnN));
    }
    faces.sort((a, b) => a.avgZ.compareTo(b.avgZ));

    // Draw shadow first (ground shadow ellipse)
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(c.dx + 14, c.dy + dieSize * 0.62),
          width: dieSize * 1.35, height: dieSize * 0.32),
      shadowPaint,
    );

    for (final face in faces) {
      _drawFace(canvas, face, fov, c);
    }
  }

  void _drawFace(Canvas canvas, _FaceData f, double fov, Offset c) {
    final path = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
    for (int i = 1; i < f.pts.length; i++) path.lineTo(f.pts[i].dx, f.pts[i].dy);
    path.close();

    final b = f.brightness;

    // Base face color — crisp white/ivory
    final faceColor = Color.fromARGB(
      255,
      (248 * b).round().clamp(60, 255),
      (242 * b).round().clamp(55, 255),
      (228 * b).round().clamp(45, 255),
    );

    // Face fill
    canvas.drawPath(path, Paint()
      ..color = faceColor
      ..style = PaintingStyle.fill);

    // Gradient overlay: simulate rounded-cube look by darkening edges
    final faceBounds = path.getBounds();
    final gradientPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(faceBounds.left + faceBounds.width * 0.38,
               faceBounds.top  + faceBounds.height * 0.35),
        faceBounds.longestSide * 0.7,
        [Colors.white.withOpacity(0.18 * b), Colors.black.withOpacity(0.22)],
        [0.0, 1.0],
      )
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(faceBounds.inflate(4), gradientPaint);
    canvas.restore();

    // Bevel highlight — top/left edges
    final bevel = Path()
      ..moveTo(f.pts[0].dx, f.pts[0].dy)
      ..lineTo(f.pts[1].dx, f.pts[1].dy)
      ..lineTo(f.pts[1].dx * 0.92 + f.pts[2].dx * 0.08,
               f.pts[1].dy * 0.92 + f.pts[2].dy * 0.08)
      ..lineTo(f.pts[0].dx * 0.92 + f.pts[3].dx * 0.08,
               f.pts[0].dy * 0.92 + f.pts[3].dy * 0.08)
      ..close();
    canvas.drawPath(bevel, Paint()
      ..color = Colors.white.withOpacity(0.28 * b)
      ..style = PaintingStyle.fill);

    // Edge outline
    canvas.drawPath(path, Paint()
      ..color = Colors.black.withOpacity(0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round);

    _drawPips(canvas, f, fov, c);
  }

  void _drawPips(Canvas canvas, _FaceData f, double fov, Offset c) {
    final v = f.value;
    if (v < 1 || v > 6) return;

    final v0 = f.v3s[0], v1 = f.v3s[1], v3 = f.v3s[3];
    final uAxis = (v1 - v0).norm;
    final vAxis = (v3 - v0).norm;
    final fc    = V3(
      f.v3s.fold(0.0, (s, v) => s + v.x) / 4,
      f.v3s.fold(0.0, (s, v) => s + v.y) / 4,
      f.v3s.fold(0.0, (s, v) => s + v.z) / 4,
    );

    final spread  = dieSize * 0.50;
    final pipR3D  = dieSize * 0.072;
    final b = f.brightness;

    for (final pip in _pips[v]) {
      final p3D = V3(
        fc.x + uAxis.x * pip.dx * spread + vAxis.x * pip.dy * spread,
        fc.y + uAxis.y * pip.dx * spread + vAxis.y * pip.dy * spread,
        fc.z + uAxis.z * pip.dx * spread + vAxis.z * pip.dy * spread,
      );
      final pC = project(p3D, fov, c);
      final pEdge = project(
        V3(p3D.x + uAxis.x * pipR3D, p3D.y + uAxis.y * pipR3D, p3D.z + uAxis.z * pipR3D),
        fov, c,
      );
      final r = (pEdge - pC).distance.clamp(4.0, 28.0);

      // Pip indent shadow
      canvas.drawCircle(pC, r + 1.5, Paint()
        ..color = Colors.black.withOpacity(0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5));

      // Pip fill — deep red
      final pipColor = Color.fromARGB(
        255,
        (185 * b).round().clamp(40, 220),
        (15  * b).round().clamp(3,  30),
        (15  * b).round().clamp(3,  30),
      );
      canvas.drawCircle(pC, r, Paint()..color = pipColor);

      // Pip gloss
      canvas.drawCircle(
        Offset(pC.dx - r * 0.30, pC.dy - r * 0.32),
        r * 0.35,
        Paint()..color = Colors.white.withOpacity(0.28 * b),
      );
    }
  }

  @override
  bool shouldRepaint(DiePainter o) => o.rx != rx || o.ry != ry;
}

class _FaceData {
  final int idx, value;
  final List<Offset> pts;
  final List<V3> v3s;
  final double brightness, avgZ;
  final V3 normal;
  _FaceData(this.idx, this.value, this.pts, this.v3s, this.brightness, this.avgZ, this.normal);
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

  List<double> _rx = [0.5];
  List<double> _ry = [0.8];
  List<AnimationController> _ctrls = [];
  List<Animation<double>> _rxA = [];
  List<Animation<double>> _ryA = [];

  @override
  void initState() {
    super.initState();
    _initDice(1);
  }

  void _initDice(int n) {
    for (final c in _ctrls) c.dispose();
    _rx = List.generate(n, (_) => 0.4 + _rand.nextDouble() * 0.3);
    _ry = List.generate(n, (_) => 0.5 + _rand.nextDouble() * 0.4);
    _results = List.filled(n, 1);
    _ctrls = List.generate(n, (_) => AnimationController(vsync: this, duration: const Duration(milliseconds: 1600)));
    _rxA = List.filled(n, const AlwaysStoppedAnimation(0));
    _ryA = List.filled(n, const AlwaysStoppedAnimation(0));
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
      final spins = 3 + _rand.nextInt(3);
      final eRx = sRx + pi * spins * (1 + _rand.nextDouble()) + tgt[0];
      final eRy = sRy + pi * spins * (1 + _rand.nextDouble()) + tgt[1];

      _ctrls[i].reset();
      _rxA[i] = Tween(begin: sRx, end: eRx)
          .animate(CurvedAnimation(parent: _ctrls[i], curve: Curves.easeInOutQuart));
      _ryA[i] = Tween(begin: sRy, end: eRy)
          .animate(CurvedAnimation(parent: _ctrls[i], curve: Curves.easeInOutQuart));

      _ctrls[i].addListener(() => setState(() {
        _rx[i] = _rxA[i].value;
        _ry[i] = _ryA[i].value;
      }));

      futures.add(Future.delayed(Duration(milliseconds: i * 100), () => _ctrls[i].forward()));
    }

    await Future.wait(futures);
    await Future.delayed(Duration(milliseconds: 1600 + (_numDice - 1) * 100));

    if (mounted) setState(() { _results = newResults; _rolling = false; });
    HapticFeedback.lightImpact();
  }

  void _setNum(int n) {
    if (_rolling || n < 1 || n > 5) return;
    setState(() { _numDice = n; _initDice(n); });
  }

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final sh = MediaQuery.of(context).size.height;
    final sum = _results.fold(0, (a, b) => a + b);

    // Die size and grid positions
    final dieSize = _numDice == 1
        ? sw * 0.38
        : _numDice <= 2
            ? sw * 0.28
            : sw * 0.22;
    final cellW = dieSize * 2.3;
    final cellH = dieSize * 2.3;
    final cols  = _numDice <= 3 ? _numDice : (_numDice == 4 ? 2 : 3);
    final rows  = (_numDice / cols).ceil();
    final gridW = cols * cellW;
    final gridH = rows * cellH;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0D1B2A), Color(0xFF1B3A2D), Color(0xFF0A1A10)],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('DICE ROLLER',
                    style: TextStyle(
                      color: Color(0xFFD4AF37),
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 5,
                    )),
                  // Count selector
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFFD4AF37).withOpacity(0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _cBtn(Icons.remove, () => _setNum(_numDice - 1), _numDice > 1 && !_rolling),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text('$_numDice',
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                      _cBtn(Icons.add, () => _setNum(_numDice + 1), _numDice < 5 && !_rolling),
                    ]),
                  ),
                ],
              ),
            ),

            // ── Dice grid ──
            Expanded(
              child: Center(
                child: SizedBox(
                  width: gridW,
                  height: gridH,
                  child: Wrap(
                    spacing: 0, runSpacing: 0,
                    alignment: WrapAlignment.center,
                    runAlignment: WrapAlignment.center,
                    children: List.generate(_numDice, (i) => GestureDetector(
                      onPanUpdate: _rolling ? null : (d) => setState(() {
                        _ry[i] += d.delta.dx * 0.01;
                        _rx[i] += d.delta.dy * 0.01;
                      }),
                      child: SizedBox(
                        width: cellW,
                        height: cellH,
                        child: CustomPaint(
                          painter: DiePainter(rx: _rx[i], ry: _ry[i], dieSize: dieSize),
                        ),
                      ),
                    )),
                  ),
                ),
              ),
            ),

            // ── Result display ──
            AnimatedOpacity(
              opacity: _rolling ? 0.15 : 1.0,
              duration: const Duration(milliseconds: 400),
              child: Column(children: [
                if (_numDice > 1) ...[
                  Text(
                    _results.map((r) => '$r').join('  ＋  '),
                    style: const TextStyle(color: Color(0xFF8B8B8B), fontSize: 16, letterSpacing: 2),
                  ),
                  const SizedBox(height: 4),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Text('SUM  ', style: TextStyle(color: Color(0xFF8B8B8B), fontSize: 13, letterSpacing: 3)),
                    Text('$sum',
                      style: const TextStyle(
                        color: Color(0xFFD4AF37), fontSize: 36,
                        fontWeight: FontWeight.w900, letterSpacing: 2,
                      )),
                  ]),
                ] else
                  Text(
                    '${_results[0]}',
                    style: const TextStyle(
                      color: Color(0xFFD4AF37), fontSize: 72,
                      fontWeight: FontWeight.w900,
                      shadows: [Shadow(color: Color(0xFFD4AF37), blurRadius: 24)],
                    ),
                  ),
              ]),
            ),

            const SizedBox(height: 16),

            // ── Roll button ──
            Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: GestureDetector(
                onTap: _roll,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _rolling
                          ? [const Color(0xFF3A2F0A), const Color(0xFF2A2206)]
                          : [const Color(0xFFE8C547), const Color(0xFFB8920A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(50),
                    boxShadow: _rolling ? [] : [
                      BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.5),
                          blurRadius: 24, spreadRadius: 1, offset: const Offset(0, 4)),
                      BoxShadow(color: const Color(0xFFD4AF37).withOpacity(0.2),
                          blurRadius: 48, spreadRadius: 4),
                    ],
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (!_rolling) const Text('🎲  ', style: TextStyle(fontSize: 18)),
                    Text(
                      _rolling ? 'ROLLING...' : 'ROLL',
                      style: TextStyle(
                        color: _rolling ? Colors.white38 : Colors.black,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cBtn(IconData icon, VoidCallback cb, bool enabled) => InkWell(
    onTap: enabled ? cb : null,
    borderRadius: BorderRadius.circular(30),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Icon(icon, color: enabled ? const Color(0xFFD4AF37) : Colors.white24, size: 18),
    ),
  );
}
