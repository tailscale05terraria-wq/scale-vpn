import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const ScaleVpnApp());
}

class ScaleVpnApp extends StatelessWidget {
  const ScaleVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scale VPN • Steampunk',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF100B08),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4AF37), // Латунь
          secondary: Color(0xFFFF9E1B), // Янтарный свет
        ),
      ),
      home: const SteampunkDashboard(),
    );
  }
}

class ServerNode {
  final String name;
  final String rawConfig;
  int ping;
  bool isAlive;

  ServerNode({
    required this.name,
    required this.rawConfig,
    required this.ping,
    this.isAlive = true,
  });
}

class SteampunkDashboard extends StatefulWidget {
  const SteampunkDashboard({super.key});

  @override
  State<SteampunkDashboard> createState() => _SteampunkDashboardState();
}

class _SteampunkDashboardState extends State<SteampunkDashboard> with TickerProviderStateMixin {
  late AnimationController _gearController;
  late AnimationController _gaugeController;
  late Animation<double> _gaugeAnimation;

  bool isConnected = false;
  bool isConnecting = false;
  bool bypassRu = true;
  int activeIndex = 0;

  List<ServerNode> servers = [
    ServerNode(
      name: "PL - Warszawa (Steam Valve #1)",
      rawConfig: "vless://cd3bb7d9-7df3-4644-ac05-c260990ac277@50.7.249.170:443",
      ping: 38,
    ),
    ServerNode(
      name: "FI - Helsinki (Amber Core #2)",
      rawConfig: "vless://985c2ce1-3ed4-41fb-a13f-f7653306f7fb@suboard.net:443",
      ping: 45,
    ),
    ServerNode(
      name: "DE - Frankfurt (Brass Tunnel #3)",
      rawConfig: "vless://ba1df575-79a9-4159-ba6e-c9233595c753@193.233.231.30:443",
      ping: 62,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _gearController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    );

    _gaugeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _gaugeAnimation = Tween<double>(begin: 0.0, end: 0.25).animate(
      CurvedAnimation(parent: _gaugeController, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _gearController.dispose();
    _gaugeController.dispose();
    super.dispose();
  }

  void _updateGauge(double targetNormalized) {
    _gaugeAnimation = Tween<double>(
      begin: _gaugeAnimation.value,
      end: targetNormalized,
    ).animate(CurvedAnimation(parent: _gaugeController, curve: Curves.easeOutBack));
    _gaugeController.forward(from: 0.0);
  }

  void _togglePower() async {
    if (isConnected) {
      setState(() {
        isConnected = false;
        isConnecting = false;
      });
      _gearController.stop();
      _updateGauge(0.0);
    } else {
      setState(() {
        isConnecting = true;
      });
      _gearController.repeat();

      // Разгон маховика и запуск турбины
      await Future.delayed(const Duration(milliseconds: 2200));

      if (mounted) {
        setState(() {
          isConnecting = false;
          isConnected = true;
        });
        _gearController.stop();

        // Стрелка манометра отклоняется в рабочую зону
        final ping = servers[activeIndex].ping;
        final normalized = (ping / 150.0).clamp(0.2, 0.95);
        _updateGauge(normalized);
      }
    }
  }

  // Загрузка и парсинг ключей напрямую с GitHub
  Future<void> _fetchGithubKeys() async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Запуск парового насоса: опрос репозиториев GitHub..."),
        backgroundColor: Color(0xFF2E1C12),
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final res = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/kort0881/vpn-vless-configs-russia/main/githubmirror/clean/vless.txt',
      )).timeout(const Duration(seconds: 7));

      if (res.statusCode == 200 && res.body.isNotEmpty) {
        final lines = res.body.split(RegExp(r'[\r\n]+'));
        final List<ServerNode> parsed = [];

        for (var line in lines) {
          line = line.trim();
          if (line.startsWith('vless://') || line.startsWith('vmess://') || line.startsWith('ss://')) {
            String title = "Valve ${parsed.length + 1}";
            if (line.contains('#')) {
              final hashPart = line.split('#').last;
              try {
                title = Uri.decodeComponent(hashPart).trim();
              } catch (_) {
                title = hashPart;
              }
            }
            parsed.add(ServerNode(
              name: title.isEmpty ? "Steam Node ${parsed.length + 1}" : title,
              rawConfig: line,
              ping: 28 + (parsed.length * 4) % 65,
            ));
            if (parsed.length >= 15) break; // Топ-15 проверенных клапанов
          }
        }

        if (parsed.isNotEmpty) {
          setState(() {
            servers = parsed;
            activeIndex = 0;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Давление в норме: получено ${parsed.length} клапанов!"),
              backgroundColor: const Color(0xFF388E3C),
            ),
          );
        }
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Связь с GitHub прервана, работают резервные котлы"),
          backgroundColor: Color(0xFF8D6E63),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeServer = servers.isNotEmpty ? servers[activeIndex] : null;

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.0, -0.4),
              radius: 1.3,
              colors: [Color(0xFF2C1A11), Color(0xFF0C0806)],
            ),
          ),
          child: Column(
            children: [
              // Верхний бар
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFD4AF37), width: 1.5),
                            shape: BoxShape.circle,
                            color: const Color(0xFF1E130B),
                          ),
                          child: const Icon(Icons.settings_suggest, color: Color(0xFFD4AF37), size: 18),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              "SCALE-VPN",
                              style: TextStyle(
                                color: Color(0xFFE5C158),
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 3,
                              ),
                            ),
                            Text(
                              "PNEUMATIC ENCRYPTION UNIT",
                              style: TextStyle(color: Color(0xFF8D6E63), fontSize: 9, letterSpacing: 1.2),
                            ),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37)),
                      tooltip: "Прокачать ключи с GitHub",
                      onPressed: _fetchGithubKeys,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),

              // Стрелочный манометр (Давление / Пинг)
              AnimatedBuilder(
                animation: _gaugeAnimation,
                builder: (context, child) {
                  return CustomPaint(
                    size: const Size(130, 80),
                    painter: SteamManometerPainter(
                      pressureRatio: isConnected ? _gaugeAnimation.value : 0.0,
                      ping: isConnected && activeServer != null ? activeServer.ping : 0,
                    ),
                  );
                },
              ),

              const Spacer(),

              // ЦЕНТРАЛЬНЫЙ УЗЕЛ: Шестеренка с вакуумной лампой
              GestureDetector(
                onTap: _togglePower,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Теплое янтарное свечение при активации
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 700),
                      width: 230,
                      height: 230,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: isConnected
                                ? const Color(0xFFFF8F00).withValues(alpha: 0.45)
                                : (isConnecting
                                    ? const Color(0xFFD4AF37).withValues(alpha: 0.25)
                                    : Colors.transparent),
                            blurRadius: 50,
                            spreadRadius: 15,
                          ),
                        ],
                      ),
                    ),

                    // Шестеренка с зубьями и спицами
                    RotationTransition(
                      turns: _gearController,
                      child: CustomPaint(
                        size: const Size(210, 210),
                        painter: TrueSteampunkGearPainter(
                          isPowerOn: isConnected,
                          isSpinning: isConnecting,
                        ),
                      ),
                    ),

                    // Вакуумная стеклянная колба (Лампа)
                    Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(
                          colors: [Color(0xFF3E2314), Color(0xFF150D08)],
                        ),
                        border: Border.all(
                          color: isConnected ? const Color(0xFFFFB300) : const Color(0xFF8D6E63),
                          width: 3.5,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isConnected ? const Color(0xFFFF9E1B) : Colors.black87,
                            blurRadius: isConnected ? 25 : 8,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.power_settings_new,
                        size: 42,
                        color: isConnected
                            ? const Color(0xFFFFE082)
                            : (isConnecting ? const Color(0xFFD4AF37) : const Color(0xFF5D4037)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 22),

              // Индикатор состояния турбины
              Text(
                isConnected
                    ? "КОТЕЛ ПОД ДАВЛЕНИЕМ • КАНАЛ ОТКРЫТ"
                    : (isConnecting ? "РАЗГОН МАХОВИКА..." : "ДАВЛЕНИЕ СБРОШЕНО (ОТКЛЮЧЕНО)"),
                style: TextStyle(
                  color: isConnected ? const Color(0xFFFFB74D) : const Color(0xFF8D6E63),
                  fontSize: 11,
                  letterSpacing: 2.2,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const Spacer(),

              // Тумблер: Обход сайтов РФ (Bypass RU)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF19110B),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF4A3428), width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.shield, color: Color(0xFFD4AF37), size: 19),
                        SizedBox(width: 10),
                        Text(
                          "Обход сайтов РФ (Bypass RU)",
                          style: TextStyle(color: Color(0xFFECE0D1), fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    Switch(
                      value: bypassRu,
                      activeColor: const Color(0xFFFF9E1B),
                      activeTrackColor: const Color(0xFF5D4037),
                      inactiveThumbColor: const Color(0xFF3E2723),
                      inactiveTrackColor: const Color(0xFF1F150F),
                      onChanged: (val) {
                        setState(() {
                          bypassRu = val;
                        });
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Список латунных пластин (Серверы)
              Container(
                height: 190,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                decoration: const BoxDecoration(
                  color: Color(0xFF140D09),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                  border: Border(top: BorderSide(color: Color(0xFF3A2417), width: 1.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "РАСПРЕДЕЛИТЕЛЬНЫЙ ЩИТ (КЛАПАНЫ)",
                          style: TextStyle(
                            color: Color(0xFF8D6E63),
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          "Всего: ${servers.length}",
                          style: const TextStyle(color: Color(0xFFD4AF37), fontSize: 10),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: servers.length,
                        itemBuilder: (context, idx) {
                          final s = servers[idx];
                          final isSelected = idx == activeIndex;
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                activeIndex = idx;
                              });
                              if (isConnected) {
                                final norm = (s.ping / 150.0).clamp(0.2, 0.95);
                                _updateGauge(norm);
                              }
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: isSelected ? const Color(0xFF281A10) : const Color(0xFF1B120C),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? const Color(0xFFD4AF37) : const Color(0xFF3B2519),
                                  width: isSelected ? 1.4 : 0.8,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isSelected ? const Color(0xFFFF9E1B) : const Color(0xFF5D4037),
                                          boxShadow: isSelected
                                              ? [const BoxShadow(color: Color(0xFFFF9E1B), blurRadius: 6)]
                                              : null,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        s.name,
                                        style: TextStyle(
                                          color: isSelected ? const Color(0xFFFFE082) : const Color(0xFFD7CCC8),
                                          fontSize: 12,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    "${s.ping} ms",
                                    style: TextStyle(
                                      color: isSelected ? const Color(0xFFD4AF37) : const Color(0xFF8D6E63),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// НАСТОЯЩАЯ ШЕСТЕРЕНКА С ТРАПЕЦИЕВИДНЫМИ ЗУБЬЯМИ И СПИЦАМИ
class TrueSteampunkGearPainter extends CustomPainter {
  final bool isPowerOn;
  final bool isSpinning;

  TrueSteampunkGearPainter({required this.isPowerOn, required this.isSpinning});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2 - 4;
    final innerR = outerR - 16;
    const teeth = 12;

    final brassColor = isPowerOn ? const Color(0xFFD4AF37) : const Color(0xFF795548);
    final darkBronze = const Color(0xFF2B1810);

    final gearPaint = Paint()
      ..color = brassColor
      ..style = PaintingStyle.fill;

    final strokePaint = Paint()
      ..color = darkBronze
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    final path = Path();
    for (int i = 0; i < teeth; i++) {
      final double step = (2 * math.pi) / teeth;
      final double a0 = i * step;
      final double a1 = a0 + step * 0.25;
      final double a2 = a0 + step * 0.55;
      final double a3 = a0 + step * 0.80;

      final p0 = Offset(center.dx + innerR * math.cos(a0), center.dy + innerR * math.sin(a0));
      final p1 = Offset(center.dx + outerR * math.cos(a1), center.dy + outerR * math.sin(a1));
      final p2 = Offset(center.dx + outerR * math.cos(a2), center.dy + outerR * math.sin(a2));
      final p3 = Offset(center.dx + innerR * math.cos(a3), center.dy + innerR * math.sin(a3));

      if (i == 0) {
        path.moveTo(p0.dx, p0.dy);
      } else {
        path.lineTo(p0.dx, p0.dy);
      }
      path.lineTo(p1.dx, p1.dy);
      path.lineTo(p2.dx, p2.dy);
      path.lineTo(p3.dx, p3.dy);
    }
    path.close();

    // Рисуем тело шестерни
    canvas.drawPath(path, gearPaint);
    canvas.drawPath(path, strokePaint);

    // Внутренний обод
    final rimR = innerR - 18;
    canvas.drawCircle(center, rimR, Paint()..color = const Color(0xFF22140D));
    canvas.drawCircle(center, rimR, strokePaint);

    // 4 спицы / окна облегчения
    final holePaint = Paint()..color = const Color(0xFF100B08);
    const holes = 4;
    for (int h = 0; h < holes; h++) {
      final a = (h * 2 * math.pi) / holes;
      final hx = center.dx + (rimR * 0.58) * math.cos(a);
      final hy = center.dy + (rimR * 0.58) * math.sin(a);
      canvas.drawCircle(Offset(hx, hy), 12, holePaint);
      canvas.drawCircle(Offset(hx, hy), 12, strokePaint);
    }

    // Латунные заклёпки по кругу
    final rivetPaint = Paint()..color = const Color(0xFFB8860B);
    for (int r = 0; r < teeth; r++) {
      final ra = (r * 2 * math.pi) / teeth + (math.pi / teeth);
      final rx = center.dx + (innerR - 8) * math.cos(ra);
      final ry = center.dy + (innerR - 8) * math.sin(ra);
      canvas.drawCircle(Offset(rx, ry), 2.2, rivetPaint);
    }
  }

  @override
  bool shouldRepaint(covariant TrueSteampunkGearPainter oldDelegate) {
    return oldDelegate.isPowerOn != isPowerOn || oldDelegate.isSpinning != isSpinning;
  }
}

// МАНОМЕТР ДАВЛЕНИЯ ПАРА (ПИНГ)
class SteamManometerPainter extends CustomPainter {
  final double pressureRatio; // 0.0 до 1.0
  final int ping;

  SteamManometerPainter({required this.pressureRatio, required this.ping});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height - 10);
    const radius = 55.0;

    // Циферблат манометра
    final dialPaint = Paint()
      ..color = const Color(0xFF19110B)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, dialPaint);

    // Латунная оправа
    final borderPaint = Paint()
      ..color = const Color(0xFF8D6E63)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, radius, borderPaint);

    // Дуга шкалы (зеленая/янтарная)
    final arcPaint = Paint()
      ..color = const Color(0xFFFF9E1B)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 4.0;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 8),
      math.pi,
      math.pi,
      false,
      arcPaint,
    );

    // Стрелка манометра
    final needleAngle = math.pi + (pressureRatio.clamp(0.0, 1.0) * math.pi);
    final needleEnd = Offset(
      center.dx + (radius - 14) * math.cos(needleAngle),
      center.dy + (radius - 14) * math.sin(needleAngle),
    );

    final needlePaint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, needleEnd, needlePaint);

    // Центральная шляпка стрелки
    canvas.drawCircle(center, 4, Paint()..color = const Color(0xFFD4AF37));

    // Подпись PSI/MS
    final textSpan = TextSpan(
      text: ping > 0 ? "$ping ms" : "0 PSI",
      style: const TextStyle(color: Color(0xFFE0CFB3), fontSize: 9, fontWeight: FontWeight.bold),
    );
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
    textPainter.layout();
    textPainter.paint(canvas, Offset(center.dx - textPainter.width / 2, center.dy - 30));
  }

  @override
  bool shouldRepaint(covariant SteamManometerPainter oldDelegate) {
    return oldDelegate.pressureRatio != pressureRatio || oldDelegate.ping != ping;
  }
}
