import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_v2ray/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ScaleVpnApp());
}

class ScaleVpnApp extends StatelessWidget {
  const ScaleVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scale VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0E0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFC5A059),
          secondary: Color(0xFFFF9800),
          surface: Color(0xFF1A1816),
        ),
      ),
      home: const MainVpnScreen(),
    );
  }
}

// ПАЛИТРА СТИМПАНК
class Palette {
  static const Color background = Color(0xFF0F0E0D);
  static const Color panel = Color(0xFF13110F);
  static const Color metal = Color(0xFF1A1816);
  static const Color metalEdge = Color(0xFF2E2924);
  static const Color brass = Color(0xFFC5A059);
  static const Color brassLight = Color(0xFFE2C485);
  static const Color brassDark = Color(0xFF8A6B2D);
  static const Color amber = Color(0xFFFF9800);
  static const Color amberSoft = Color(0xFFFFB74D);
  static const Color textPrimary = Color(0xFFE8E4DF);
  static const Color textMuted = Color(0xFF8C827A);
  static const Color danger = Color(0xFFE53935);
  static const Color good = Color(0xFF66BB6A);
  static const Color average = Color(0xFFFFC107);

  static const LinearGradient brassGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE2C485), Color(0xFFC5A059), Color(0xFF8A6B2D)],
    stops: [0.0, 0.52, 1.0],
  );

  static const LinearGradient steelGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF57504A), Color(0xFF413B36), Color(0xFF2A2622)],
    stops: [0.0, 0.52, 1.0],
  );
}

Color tint(int r, int g, int b, double fraction) {
  final double f = fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
  return Color.fromARGB((f * 255).round(), r, g, b);
}

Color amberTint(double fraction) => tint(0xFF, 0x98, 0x00, fraction);
Color brassTint(double fraction) => tint(0xC5, 0xA0, 0x59, fraction);
Color whiteTint(double fraction) => tint(0xFF, 0xFF, 0xFF, fraction);

class ServerNode {
  final String name;
  final String rawConfig;
  int ping; // -2: замер, -1: таймаут, >0: мс
  final bool isCustom;
  bool isPinned;

  ServerNode({
    required this.name,
    required this.rawConfig,
    required this.ping,
    this.isCustom = false,
    this.isPinned = false,
  });
}

class MainVpnScreen extends StatefulWidget {
  const MainVpnScreen({super.key});

  @override
  State<MainVpnScreen> createState() => _MainVpnScreenState();
}

class _MainVpnScreenState extends State<MainVpnScreen> with TickerProviderStateMixin {
  late AnimationController _gearController;
  late AnimationController _glowController;

  bool _isManuallyStopped = false;
  bool _isReconnecting = false;

  late final FlutterV2ray flutterV2ray = FlutterV2ray(
    onStatusChanged: (status) {
      if (!mounted) return;
      if (_isManuallyStopped || _isReconnecting) return;

      final stateStr = status.state.toUpperCase().trim();

      if (stateStr == "CONNECTED") {
        setState(() {
          isConnected = true;
          isConnecting = false;
        });
        _gearController.stop();
      } else if (stateStr == "DISCONNECTED" || stateStr == "STOPPED") {
        setState(() {
          isConnected = false;
          isConnecting = false;
        });
        _gearController.stop();
        _gearController.reset();
      } else if (stateStr == "CONNECTING") {
        setState(() {
          isConnecting = true;
          isConnected = false;
        });
        _gearController.repeat();
      }
    },
  );

  bool isConnected = false;
  bool isConnecting = false;
  bool isSearchingGitHub = false;
  String searchStatusText = "";

  int currentTab = 0; // 0 - GitHub, 1 - Свои ключи
  int selectedIndex = 0;

  List<ServerNode> autoServers = [];
  List<ServerNode> customServers = [];
  Set<String> pinnedConfigs = {};

  final Map<String, int> _deadKeys = {};
  static const int _deadKeyTtlMs = 3 * 60 * 60 * 1000; // 3 часа

  // Параметры выборки: ищем около 10-15 стабильных ключей
  static const int _targetWorkingNodes = 12;
  static const int _maxCandidatesToInspect = 36;
  int _sourceRotationIndex = 0;

  final math.Random _random = math.Random();

  // ПРОВЕРЕННЫЕ ССЫЛКИ IGARECK + НАДЕЖНЫЕ ЗЕРКАЛА ДЛЯ РФ
  final List<String> vpnSources = [
    // Прямые ссылки на репозиторий
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt',
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/Vless-Reality-White-Lists-Rus-Mobile.txt',
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS.txt',
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_SS%2BAll_RUS.txt',
    // Зеркала githack и jsdelivr (работают даже при блокировке raw.githubusercontent.com)
    'https://raw.githack.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt',
    'https://raw.githack.com/igareck/vpn-configs-for-russia/main/Vless-Reality-White-Lists-Rus-Mobile.txt',
    'https://fastly.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_VLESS_RUS_mobile.txt',
    'https://fastly.jsdelivr.net/gh/kort0881/vpn-vless-configs-russia@main/githubmirror/clean/vless.txt',
  ];

  @override
  void initState() {
    super.initState();
    _gearController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _initV2RayEngine();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadStoredData();
    if (!mounted) return;
    // Если список пуст, запускаем автопоиск
    if (autoServers.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchGitHubForKeys());
    }
  }

  void _initV2RayEngine() async {
    try {
      await flutterV2ray.initializeV2Ray();
    } catch (_) {}
  }

  @override
  void dispose() {
    _gearController.dispose();
    _glowController.dispose();
    super.dispose();
  }

  // ХРАНИЛИЩЕ И МИГРАЦИЯ ЧЕРНОГО СПИСКА

  Future<void> _loadStoredData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // ОЧИСТКА СТАРОГО «ОТРАВЛЕННОГО» ЧЕРНОГО СПИСКА
      final int blacklistVersion = prefs.getInt('blacklist_version_v3') ?? 0;
      if (blacklistVersion < 3) {
        await prefs.remove('dead_endpoints');
        _deadKeys.clear();
        await prefs.setInt('blacklist_version_v3', 3);
      } else {
        final dead = prefs.getStringList('dead_endpoints') ?? [];
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final entry in dead) {
          final parts = entry.split('|');
          if (parts.length != 2) continue;
          final ts = int.tryParse(parts[1]) ?? 0;
          if (now - ts < _deadKeyTtlMs) {
            _deadKeys[parts[0]] = ts;
          }
        }
      }

      final pinnedList = prefs.getStringList('pinned_vpn_configs') ?? [];
      pinnedConfigs = pinnedList.toSet();

      final saved = prefs.getStringList('custom_vpn_keys') ?? [];
      if (saved.isNotEmpty && mounted) {
        setState(() {
          customServers = saved.map((str) {
            final parts = str.split('::');
            final config = parts.length > 1 ? parts[1] : str;
            return ServerNode(
              name: parts.isNotEmpty ? parts[0] : "Свой узел",
              rawConfig: config,
              ping: -2,
              isCustom: true,
              isPinned: pinnedConfigs.contains(config),
            );
          }).toList();
          _sortNodes(customServers);
        });
      }
    } catch (_) {}
  }

  Future<void> _saveCustomKeysToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = customServers.map((s) => "${s.name}::${s.rawConfig}").toList();
      await prefs.setStringList('custom_vpn_keys', list);
    } catch (_) {}
  }

  Future<void> _savePinnedKeysToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('pinned_vpn_configs', pinnedConfigs.toList());
    } catch (_) {}
  }

  Future<void> _saveDeadKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      _deadKeys.removeWhere((key, ts) => now - ts >= _deadKeyTtlMs);

      final list = _deadKeys.entries.map((e) => "${e.key}|${e.value}").toList();
      await prefs.setStringList('dead_endpoints', list);
    } catch (_) {}
  }

  String _configHash(String rawConfig) {
    return rawConfig.split('#').first.trim();
  }

  bool _isBlacklisted(String rawConfig) {
    final key = _configHash(rawConfig);
    final ts = _deadKeys[key];
    if (ts == null) return false;
    if (DateTime.now().millisecondsSinceEpoch - ts >= _deadKeyTtlMs) {
      _deadKeys.remove(key);
      return false;
    }
    return true;
  }

  void _markDead(String rawConfig) {
    if (pinnedConfigs.contains(rawConfig)) return;
    _deadKeys[_configHash(rawConfig)] = DateTime.now().millisecondsSinceEpoch;
  }

  void _markAlive(String rawConfig) {
    _deadKeys.remove(_configHash(rawConfig));
  }

  // БЕЗОПАСНАЯ КОНФИГУРАЦИЯ XRAY

  String? _buildCleanConfig(String rawConfig) {
    try {
      final v2rayURL = FlutterV2ray.parseFromURL(rawConfig);
      try {
        if (v2rayURL.inbound is Map) {
          v2rayURL.inbound['sniffing'] = {
            "enabled": true,
            "destOverride": ["http", "tls"],
            "routeOnly": false
          };
        }
      } catch (_) {}
      return v2rayURL.getFullConfiguration();
    } catch (_) {
      return null;
    }
  }

  void _sortNodes(List<ServerNode> list) {
    final currentSelected = (list.isNotEmpty && selectedIndex < list.length)
        ? list[selectedIndex]
        : null;

    list.sort((a, b) {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;

      int score(ServerNode n) {
        if (n.ping > 0) return n.ping;
        if (n.ping == -2) return 99999;
        return 999999;
      }

      return score(a).compareTo(score(b));
    });

    if (currentSelected != null) {
      final newIdx = list.indexOf(currentSelected);
      if (newIdx != -1) {
        selectedIndex = newIdx;
      }
    }
  }

  void _togglePin(ServerNode item) {
    setState(() {
      item.isPinned = !item.isPinned;
      if (item.isPinned) {
        pinnedConfigs.add(item.rawConfig);
        _markAlive(item.rawConfig);
        _showToast("Узел закреплен вверху списка", isSuccess: true);
      } else {
        pinnedConfigs.remove(item.rawConfig);
        _showToast("Узел откреплен", isSuccess: false);
      }
      final list = currentTab == 0 ? autoServers : customServers;
      _sortNodes(list);
    });
    _savePinnedKeysToStorage();
  }

  List<String> _extractConfigs(String rawData) {
    List<String> results = [];
    String text = rawData;

    // Проверка Base64 (если ссылка является подпиской)
    try {
      String cleaned = rawData.replaceAll(RegExp(r'\s+'), '');
      if (cleaned.length % 4 == 0 && !cleaned.contains('://')) {
        final decoded = utf8.decode(base64.decode(cleaned));
        if (decoded.contains('://')) {
          text = decoded;
        }
      }
    } catch (_) {}

    final lines = text.split(RegExp(r'[\r\n]+'));
    for (var line in lines) {
      line = line.trim();
      // Строго принимаем только протоколы, поддерживаемые ядром flutter_v2ray
      // (исключаем hysteria2://, tuic://, которые вызывают сбой)
      if (line.startsWith('vless://') ||
          line.startsWith('ss://') ||
          line.startsWith('vmess://') ||
          line.startsWith('trojan://')) {
        results.add(line);
      }
    }
    return results;
  }

  // ПОИСК И АВТОМАТИЧЕСКАЯ КАЛИБРОВКА 10-15 РАБОЧИХ КЛЮЧЕЙ

  Future<void> _searchGitHubForKeys() async {
    if (isSearchingGitHub) return;
    setState(() {
      isSearchingGitHub = true;
      searchStatusText = "Загрузка реестров РФ...";
    });

    _showToast("Опрос проверенных реестров igareck", isSuccess: true);

    try {
      await _runSmartDiscovery();
    } catch (_) {
      if (mounted) _showToast("Сбой при опросе источников", isSuccess: false);
    } finally {
      await _saveDeadKeys();
      if (mounted) {
        setState(() {
          isSearchingGitHub = false;
          searchStatusText = "";
        });
      }
    }
  }

  Future<void> _runSmartDiscovery() async {
    // 1. Скачиваем 2-3 источника со сдвигом ротации
    final activeBatch = <String>[];
    final totalSources = vpnSources.length;
    for (int i = 0; i < 3; i++) {
      activeBatch.add(vpnSources[(_sourceRotationIndex + i) % totalSources]);
    }
    _sourceRotationIndex = (_sourceRotationIndex + 2) % totalSources;

    final pool = <String>{};

    for (final url in activeBatch) {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 7));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          final extracted = _extractConfigs(res.body);
          pool.addAll(extracted);
        }
      } catch (_) {}
    }

    if (pool.isEmpty) {
      // Резервная попытка через прямой jsdelivr
      try {
        final res = await http.get(Uri.parse(
          'https://fastly.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_VLESS_RUS_mobile.txt',
        )).timeout(const Duration(seconds: 7));
        if (res.statusCode == 200) {
          pool.addAll(_extractConfigs(res.body));
        }
      } catch (_) {}
    }

    if (pool.isEmpty) {
      if (mounted) _showToast("Не удалось загрузить списки ключей", isSuccess: false);
      return;
    }

    // 2. Отсеиваем черный список и перемешиваем для получения свежих узлов
    List<String> candidates = pool.where((c) => !_isBlacklisted(c)).toList();
    if (candidates.length < 15) {
      candidates = pool.toList(); // Если пул мал, даем второй шанс
    }
    candidates.shuffle(_random);

    // Берем пачку для последовательной проверки (до 36 кандидатов)
    final toTest = candidates.take(_maxCandidatesToInspect).toList();

    // Сохраняем закрепленные пользователем узлы
    final List<ServerNode> workingNodes = autoServers.where((s) => s.isPinned).toList();

    if (mounted) {
      setState(() {
        searchStatusText = "Проверка задержки узлов...";
        autoServers = List.from(workingNodes);
      });
    }

    int testedCount = 0;

    // 3. ПОСЛЕДОВАТЕЛЬНЫЙ ЗАМЕР ЧЕРЕЗ XRAY (защита от конфликта портов)
    for (final config in toTest) {
      if (!mounted) break;
      if (workingNodes.length >= _targetWorkingNodes) {
        // Набрали 10-15 рабочих ключей — МГНОВЕННЫЙ СТОП
        break;
      }

      testedCount++;
      setState(() {
        searchStatusText = "Найдено рабочих: ${workingNodes.length}/$_targetWorkingNodes (шаг $testedCount)";
      });

      final int delay = await _testRealDelayInternal(config);

      if (delay > 0) {
        _markAlive(config);

        String title = "Узел ${workingNodes.length + 1}";
        if (config.contains('#')) {
          try {
            title = Uri.decodeComponent(config.split('#').last).trim();
          } catch (_) {
            title = config.split('#').last.trim();
          }
        }
        if (title.isEmpty) title = "Узел ${workingNodes.length + 1}";
        if (title.length > 40) title = title.substring(0, 40);

        final newNode = ServerNode(
          name: title,
          rawConfig: config,
          ping: delay,
          isPinned: pinnedConfigs.contains(config),
        );

        workingNodes.add(newNode);
        _sortNodes(workingNodes);

        if (mounted) {
          setState(() {
            autoServers = List.from(workingNodes);
            if (selectedIndex >= autoServers.length) selectedIndex = 0;
          });
        }
      } else {
        _markDead(config);
      }
    }

    if (!mounted) return;

    setState(() {
      autoServers = workingNodes;
      _sortNodes(autoServers);
      selectedIndex = 0;
    });

    if (autoServers.isEmpty) {
      _showToast("Активных узлов не найдено. Нажмите еще раз для другой пачки", isSuccess: false);
    } else {
      _showToast("Готово! Отобрано рабочих узлов: ${autoServers.length}", isSuccess: true);
    }
  }

  // ЗАМЕР ЧЕРЕЗ XRAY (реальный запрос до Google 204)
  Future<int> _testRealDelayInternal(String rawConfig) async {
    final cleanConfig = _buildCleanConfig(rawConfig);
    if (cleanConfig == null) return -1;

    try {
      final delay = await flutterV2ray
          .getServerDelay(
            config: cleanConfig,
            url: 'https://www.gstatic.com/generate_204',
          )
          .timeout(const Duration(milliseconds: 3600), onTimeout: () => -1);
      return delay;
    } catch (_) {
      return -1;
    }
  }

  Future<void> _testNodeRealDelay(ServerNode node) async {
    if (!mounted) return;
    setState(() => node.ping = -2);

    int delay = -1;
    final activeList = currentTab == 0 ? autoServers : customServers;
    final isCurrentlyConnectedNode = isConnected &&
        activeList.isNotEmpty &&
        selectedIndex < activeList.length &&
        activeList[selectedIndex] == node;

    try {
      if (isCurrentlyConnectedNode) {
        delay = await flutterV2ray
            .getConnectedServerDelay(url: 'https://www.gstatic.com/generate_204')
            .timeout(const Duration(milliseconds: 3600), onTimeout: () => -1);
      } else {
        final cleanConfig = _buildCleanConfig(node.rawConfig);
        if (cleanConfig != null) {
          delay = await flutterV2ray
              .getServerDelay(
                config: cleanConfig,
                url: 'https://www.gstatic.com/generate_204',
              )
              .timeout(const Duration(milliseconds: 3600), onTimeout: () => -1);
        }
      }
    } catch (_) {
      delay = -1;
    }

    if (delay > 0) {
      _markAlive(node.rawConfig);
    } else {
      _markDead(node.rawConfig);
    }

    if (mounted) {
      setState(() {
        node.ping = delay;
        _sortNodes(activeList);
      });
    }
  }

  // УПРАВЛЕНИЕ ПОДКЛЮЧЕНИЕМ

  Future<void> _selectAndSwitchServer(int idx) async {
    final activeList = currentTab == 0 ? autoServers : customServers;
    if (activeList.isEmpty || idx >= activeList.length) return;

    final targetNode = activeList[idx];

    if ((isConnected || isConnecting) && idx != selectedIndex) {
      setState(() {
        selectedIndex = idx;
        _isReconnecting = true;
        isConnecting = true;
        isConnected = false;
      });
      _gearController.repeat();

      try {
        await flutterV2ray.stopV2Ray();
        await Future.delayed(const Duration(milliseconds: 200));
        if (mounted) setState(() => _isReconnecting = false);
        await _startTunnel(targetNode);
      } catch (_) {
        if (mounted) {
          setState(() {
            isConnecting = false;
            isConnected = false;
          });
          _gearController.stop();
          _showToast("Ошибка при переподключении", isSuccess: false);
        }
      } finally {
        if (mounted) setState(() => _isReconnecting = false);
      }
      return;
    }

    setState(() => selectedIndex = idx);

    if (targetNode.ping == -2) {
      _testNodeRealDelay(targetNode);
    }
  }

  Future<void> _startTunnel(ServerNode node) async {
    _isManuallyStopped = false;
    setState(() => isConnecting = true);
    _gearController.repeat();

    try {
      final bool permissionGranted = await flutterV2ray.requestPermission();

      if (permissionGranted) {
        final cleanConfig = _buildCleanConfig(node.rawConfig);

        if (cleanConfig == null) {
          throw Exception("Неверный формат конфигурации");
        }

        await flutterV2ray.startV2Ray(
          remark: node.name,
          config: cleanConfig,
          proxyOnly: false,
          bypassSubnets: null,
          notificationDisconnectButtonName: "ОТКЛЮЧИТЬ",
        );

        if (mounted) {
          _showToast("Подключено: ${node.name}", isSuccess: true);
        }
      } else {
        if (mounted) {
          setState(() => isConnecting = false);
          _gearController.stop();
          _showToast("Требуется системное разрешение VPN", isSuccess: false);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => isConnecting = false);
        _gearController.stop();
        _showToast("Ошибка запуска ядра Xray", isSuccess: false);
      }
    }
  }

  void _handleToggle() async {
    final activeList = currentTab == 0 ? autoServers : customServers;
    if (activeList.isEmpty) {
      _showToast("Список пуст. Выполняется поиск узлов...", isSuccess: false);
      if (currentTab == 0 && !isSearchingGitHub) _searchGitHubForKeys();
      return;
    }

    if (isConnected || isConnecting) {
      _isManuallyStopped = true;
      setState(() {
        isConnected = false;
        isConnecting = false;
      });
      _gearController.stop();
      _gearController.reset();

      try {
        await flutterV2ray.stopV2Ray();
      } catch (_) {}

      _showToast("VPN отключен", isSuccess: false);
      return;
    }

    _startTunnel(activeList[selectedIndex]);
  }

  void _purgeDeadNodes() {
    final list = currentTab == 0 ? autoServers : customServers;
    if (list.isEmpty) return;

    final before = list.length;
    setState(() {
      for (final node in list) {
        if (!node.isPinned && node.ping <= 0 && node.ping != -2) {
          _markDead(node.rawConfig);
        }
      }
      list.removeWhere((s) => !s.isPinned && s.ping <= 0 && s.ping != -2);
      _sortNodes(list);
      if (selectedIndex >= list.length) selectedIndex = 0;
    });

    _saveDeadKeys();

    final removedCount = before - list.length;
    if (currentTab == 1) {
      _saveCustomKeysToStorage();
    }

    if (removedCount > 0) {
      _showToast("Удалено узлов: $removedCount", isSuccess: true);
    } else {
      _showToast("Все узлы активны", isSuccess: true);
    }

    if (currentTab == 0 && autoServers.isEmpty && !isSearchingGitHub) {
      _searchGitHubForKeys();
    }
  }

  void _showToast(String message, {required bool isSuccess}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle_outline : Icons.error_outline,
              size: 16,
              color: isSuccess ? const Color(0xFFA5D6A7) : const Color(0xFFFFCDD2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: isSuccess ? const Color(0xFF1E4620) : const Color(0xFF4A1C1C),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        duration: const Duration(milliseconds: 2200),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isSuccess ? const Color(0xFF3D7A40) : const Color(0xFF8E3B3B),
            width: 1,
          ),
        ),
      ),
    );
  }

  // ДИАЛОГИ

  void _showAddKeyDialog() {
    final nameController = TextEditingController();
    final configController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1B1917),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Palette.brass, width: 1.2),
        ),
        title: Row(
          children: const [
            Icon(Icons.add_link, color: Palette.brass),
            SizedBox(width: 10),
            Text("Добавить свой ключ",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Название узла",
                  hintStyle: const TextStyle(color: Color(0xFF756D65), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF13110F),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3B352E))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Palette.brass)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: configController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  hintText: "Вставьте ключ формата vless:// или ss://",
                  hintStyle: const TextStyle(color: Color(0xFF756D65), fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF13110F),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF3B352E))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Palette.brass)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ОТМЕНА", style: TextStyle(color: Color(0xFF8C827A))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Palette.brass),
            onPressed: () {
              final raw = configController.text.trim();
              if (raw.isEmpty) return;

              String title = nameController.text.trim();
              if (title.isEmpty) {
                if (raw.contains('#')) {
                  try {
                    title = Uri.decodeComponent(raw.split('#').last).trim();
                  } catch (_) {
                    title = raw.split('#').last;
                  }
                }
              }
              if (title.isEmpty) title = "Свой узел ${customServers.length + 1}";

              final newNode = ServerNode(
                name: title,
                rawConfig: raw,
                ping: -2,
                isCustom: true,
                isPinned: pinnedConfigs.contains(raw),
              );

              setState(() {
                customServers.insert(0, newNode);
                currentTab = 1;
                selectedIndex = 0;
                _sortNodes(customServers);
              });

              _saveCustomKeysToStorage();
              _testNodeRealDelay(newNode);
              Navigator.pop(context);
              _showToast("Ключ сохранен", isSuccess: true);
            },
            child: const Text("ДОБАВИТЬ",
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1B1917),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Palette.brass, width: 1.2),
        ),
        title: Row(
          children: const [
            Icon(Icons.info_outline, color: Palette.brass),
            SizedBox(width: 10),
            Text("О системе Scale VPN",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Принципы автоматического подбора:",
                style: TextStyle(color: Palette.brass, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              const Text(
                "• База igareck для РФ:\n"
                "Приложение подключается к репозиториям с конфигурациями VLESS Reality, адаптированными под обход ТСПУ.\n\n"
                "• Умный лимит (10-15 узлов):\n"
                "Вместо загрузки всех 500+ ключей система последовательно проверяет кандидатов до набора 12 гарантированно рабочих узлов.\n\n"
                "• Честный Real Delay:\n"
                "Замер производится напрямую встроенным ядром Xray без сторонних эмуляций.\n\n"
                "• Без дедлоков:\n"
                "Замер каждого узла изолирован от сетевых конфликтов Android-стека.",
                style: TextStyle(color: Color(0xFFD6D3D1), fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 10),
              Text(
                "Временный фильтр: ${_deadKeys.length} узлов",
                style: const TextStyle(color: Palette.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ЗАКРЫТЬ",
                style: TextStyle(color: Palette.brass, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // ГРАФИЧЕСКИЕ КОМПОНЕНТЫ

  Color _pingColor(int ping) {
    if (ping <= 0) return Palette.danger;
    if (ping < 350) return Palette.good;
    if (ping < 900) return Palette.average;
    return const Color(0xFFFF7043);
  }

  int _signalBars(int ping) {
    if (ping <= 0) return 0;
    if (ping < 350) return 3;
    if (ping < 900) return 2;
    return 1;
  }

  Widget _buildPingBadge(int ping) {
    if (ping == -2) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: Palette.brass),
      );
    }
    if (ping <= 0) {
      return const Text(
        "Таймаут",
        style: TextStyle(color: Palette.danger, fontSize: 11, fontWeight: FontWeight.bold),
      );
    }
    return Text(
      "$ping ms",
      style: TextStyle(color: _pingColor(ping), fontSize: 11, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildSignalMeter(int ping) {
    final bars = _signalBars(ping);
    final color = _pingColor(ping);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(3, (i) {
        final active = i < bars;
        return Container(
          margin: const EdgeInsets.only(left: 2),
          width: 3.5,
          height: 5.0 + i * 3.5,
          decoration: BoxDecoration(
            color: active ? color : const Color(0xFF3A342E),
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  Widget _buildGauge(ServerNode? node) {
    final ping = node?.ping ?? -1;
    final hasNode = node != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1D1A17), Color(0xFF131110)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF3A332B), width: 1.1),
        boxShadow: const [
          BoxShadow(color: Color(0x99000000), blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: isConnected ? Palette.brassGradient : Palette.steelGradient,
              boxShadow: const [BoxShadow(color: Color(0xAA000000), blurRadius: 4)],
            ),
            child: Icon(
              Icons.speed,
              size: 13,
              color: isConnected ? const Color(0xFF2A2010) : const Color(0xFF9C948B),
            ),
          ),
          const SizedBox(width: 10),
          const Text("ЗАДЕРЖКА",
              style: TextStyle(
                  color: Palette.textMuted, fontSize: 9.5, letterSpacing: 1.4, fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Container(width: 1, height: 16, color: const Color(0xFF322C26)),
          const SizedBox(width: 8),
          hasNode
              ? _buildPingBadge(ping)
              : const Text("—", style: TextStyle(color: Palette.textMuted, fontSize: 11)),
          const SizedBox(width: 8),
          _buildSignalMeter(hasNode ? ping : -1),
        ],
      ),
    );
  }

  Widget _buildBrassIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Widget? customChild,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onPressed,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF221F1B), Color(0xFF161412)],
                ),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: const Color(0xFF3A332B), width: 1),
              ),
              child: Center(
                child: customChild ?? Icon(icon, color: Palette.brass, size: 18),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeList = currentTab == 0 ? autoServers : customServers;
    final activeNode =
        activeList.isNotEmpty && selectedIndex < activeList.length ? activeList[selectedIndex] : null;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.35),
            radius: 1.1,
            colors: [Color(0xFF17150F), Palette.background],
            stops: [0.0, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              const Spacer(),
              _buildPowerControl(),
              const SizedBox(height: 18),
              _buildStatusLabel(),
              const SizedBox(height: 10),
              _buildGauge(activeNode),
              const Spacer(),
              _buildServerPanel(activeList),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: Palette.brassGradient,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(color: Color(0xAA000000), blurRadius: 8, offset: Offset(0, 3)),
                  ],
                ),
                child: const Icon(Icons.security, color: Color(0xFF241B0C), size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (rect) => Palette.brassGradient.createShader(rect),
                    child: const Text(
                      "SCALE VPN",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.5,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 1),
                  const Text(
                    "REALITY FOR RUSSIA",
                    style: TextStyle(color: Palette.textMuted, fontSize: 9, letterSpacing: 1.2),
                  ),
                ],
              ),
            ],
          ),
          Row(
            children: [
              _buildBrassIconButton(
                icon: Icons.cleaning_services_outlined,
                tooltip: "Удалить нерабочие узлы",
                onPressed: _purgeDeadNodes,
              ),
              _buildBrassIconButton(
                icon: Icons.info_outline,
                tooltip: "О системе",
                onPressed: _showInfoDialog,
              ),
              _buildBrassIconButton(
                icon: Icons.sync,
                tooltip: "Синхронизация узлов",
                onPressed: isSearchingGitHub ? null : _searchGitHubForKeys,
                customChild: isSearchingGitHub
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(color: Palette.brass, strokeWidth: 2),
                      )
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPowerControl() {
    return GestureDetector(
      onTap: _handleToggle,
      child: AnimatedBuilder(
        animation: _glowController,
        builder: (context, child) {
          final pulse = 0.6 + (_glowController.value * 0.4);
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 226,
                height: 226,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: isConnected ? amberTint(0.22 * pulse) : Colors.transparent,
                      blurRadius: 48,
                      spreadRadius: 12,
                    ),
                  ],
                ),
              ),
              CustomPaint(
                size: const Size(206, 206),
                painter: BezelPainter(isActive: isConnected),
              ),
              RotationTransition(
                turns: _gearController,
                child: CustomPaint(
                  size: const Size(186, 186),
                  painter: PolishedGearPainter(isActive: isConnected),
                ),
              ),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    center: Alignment(-0.3, -0.4),
                    radius: 1.0,
                    colors: [Color(0xFF262220), Color(0xFF121010), Color(0xFF0A0908)],
                    stops: [0.0, 0.6, 1.0],
                  ),
                  border: Border.all(
                    color: isConnected ? Palette.amber : const Color(0xFF4A443E),
                    width: 2.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: isConnected ? amberTint(0.45 * pulse) : Colors.black87,
                      blurRadius: isConnected ? 20 : 6,
                      spreadRadius: isConnected ? 1 : 0,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.power_settings_new,
                  size: 38,
                  color: isConnected
                      ? Palette.amberSoft
                      : (_isReconnecting || isConnecting ? Palette.brass : const Color(0xFF6B635B)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusLabel() {
    final String label = isConnected
        ? "СОЕДИНЕНИЕ АКТИВНО"
        : (_isReconnecting
            ? "ПЕРЕПОДКЛЮЧЕНИЕ..."
            : (isConnecting
                ? "ПОДКЛЮЧЕНИЕ..."
                : (isSearchingGitHub ? searchStatusText : "ОТКЛЮЧЕНО")));

    final Color color = isConnected
        ? Palette.amberSoft
        : (_isReconnecting || isConnecting || isSearchingGitHub
            ? Palette.brass
            : const Color(0xFF9E948A));

    return Column(
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: color,
            fontSize: 12.0,
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: 120,
          height: 1.2,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.transparent,
                isConnected ? amberTint(0.8) : const Color(0xFF3A332B),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildServerPanel(List<ServerNode> activeList) {
    return Container(
      height: 256,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF181513), Palette.panel],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: Color(0xFF3A332B), width: 1.2)),
        boxShadow: [BoxShadow(color: Color(0xCC000000), blurRadius: 18, offset: Offset(0, -6))],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  _buildTabButton("Узлы РФ (Авто)", 0),
                  const SizedBox(width: 8),
                  _buildTabButton("Свои ключи", 1),
                ],
              ),
              Row(
                children: [
                  if (currentTab == 1)
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, color: Palette.brass, size: 21),
                      tooltip: "Добавить ключ",
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                      onPressed: _showAddKeyDialog,
                    ),
                  IconButton(
                    icon: const Icon(Icons.cleaning_services, color: Palette.brass, size: 17),
                    tooltip: "Очистить нерабочие узлы",
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                    onPressed: _purgeDeadNodes,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: activeList.isEmpty ? _buildEmptyState() : _buildNodeList(activeList),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    if (isSearchingGitHub) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(color: Palette.brass, strokeWidth: 2.2),
            ),
            const SizedBox(height: 12),
            Text(searchStatusText,
                style: const TextStyle(color: Palette.textMuted, fontSize: 11.5, letterSpacing: 0.5)),
          ],
        ),
      );
    }

    if (currentTab == 1) {
      return Center(
        child: TextButton.icon(
          icon: const Icon(Icons.add_link, color: Palette.brass, size: 16),
          label: const Text("Добавить собственный ключ",
              style: TextStyle(color: Palette.brass, fontSize: 12)),
          onPressed: _showAddKeyDialog,
        ),
      );
    }

    return Center(
      child: TextButton.icon(
        icon: const Icon(Icons.travel_explore, color: Palette.brass, size: 16),
        label: const Text("Найти рабочие узлы в реестрах",
            style: TextStyle(color: Palette.brass, fontSize: 12)),
        onPressed: _searchGitHubForKeys,
      ),
    );
  }

  Widget _buildNodeList(List<ServerNode> activeList) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: activeList.length,
      itemBuilder: (context, idx) {
        final item = activeList[idx];
        final isCurrent = idx == selectedIndex;

        return GestureDetector(
          onTap: () => _selectAndSwitchServer(idx),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: isCurrent
                    ? [const Color(0xFF2A241D), const Color(0xFF1D1916)]
                    : [const Color(0xFF1B1916), const Color(0xFF161412)],
              ),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: isCurrent ? Palette.brass : const Color(0xFF2E2924),
                width: isCurrent ? 1.2 : 0.8,
              ),
              boxShadow: isCurrent
                  ? const [BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2))]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: item.isPinned
                        ? Palette.amber
                        : (isCurrent ? Palette.brass : const Color(0xFF5A524A)),
                    boxShadow: isCurrent || item.isPinned
                        ? [
                            BoxShadow(
                              color: item.isPinned ? amberTint(0.5) : brassTint(0.5),
                              blurRadius: 6,
                            )
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 9),
                if (item.isPinned)
                  const Padding(
                    padding: EdgeInsets.only(right: 5),
                    child: Icon(Icons.push_pin, size: 12.5, color: Palette.amber),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? Colors.white : Palette.textPrimary,
                          fontSize: 12,
                          fontWeight: (isCurrent || item.isPinned) ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          _buildPingBadge(item.ping),
                          const SizedBox(width: 6),
                          if (item.ping > 0) _buildSignalMeter(item.ping),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        item.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                        size: 16,
                        color: item.isPinned ? Palette.amber : Palette.textMuted,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: item.isPinned ? "Открепить узел" : "Закрепить узел вверху",
                      onPressed: () => _togglePin(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.network_check, size: 16, color: Palette.brass),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: "Замерить задержку",
                      onPressed: () => _testNodeRealDelay(item),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 15, color: Palette.textMuted),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: "Скопировать ключ",
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: item.rawConfig));
                        _showToast("Ключ скопирован в буфер", isSuccess: true);
                      },
                    ),
                    if (item.isCustom)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 16, color: Color(0xFFC62828)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        tooltip: "Удалить",
                        onPressed: () {
                          setState(() {
                            customServers.remove(item);
                            pinnedConfigs.remove(item.rawConfig);
                            if (selectedIndex >= customServers.length) selectedIndex = 0;
                          });
                          _saveCustomKeysToStorage();
                          _savePinnedKeysToStorage();
                          _showToast("Ключ удален", isSuccess: false);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabButton(String title, int index) {
    final isSelected = currentTab == index;
    return GestureDetector(
      onTap: () => setState(() {
        currentTab = index;
        selectedIndex = 0;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF322A20), Color(0xFF221D18)],
                )
              : null,
          color: isSelected ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Palette.brass : const Color(0xFF332E29),
            width: 1,
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? Palette.brass : Palette.textMuted,
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

// БЕЗЕЛЬ
class BezelPainter extends CustomPainter {
  final bool isActive;

  BezelPainter({required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..shader = (isActive ? Palette.brassGradient : Palette.steelGradient).createShader(rect);

    canvas.drawCircle(center, radius, ringPaint);

    final tickPaint = Paint()
      ..color = isActive ? const Color(0xFF6E5626) : const Color(0xFF2C2723)
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    const ticks = 60;
    for (int i = 0; i < ticks; i++) {
      final a = (i * 2 * math.pi) / ticks;
      final isMajor = i % 5 == 0;
      final rOuter = radius - 5;
      final rInner = radius - (isMajor ? 12 : 8);
      canvas.drawLine(
        Offset(center.dx + rInner * math.cos(a), center.dy + rInner * math.sin(a)),
        Offset(center.dx + rOuter * math.cos(a), center.dy + rOuter * math.sin(a)),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BezelPainter oldDelegate) => oldDelegate.isActive != isActive;
}

// ЛАТУННАЯ ШЕСТЕРНЯ
class PolishedGearPainter extends CustomPainter {
  final bool isActive;

  PolishedGearPainter({required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2 - 4;
    final innerR = outerR - 15;
    const teeth = 12;

    final rect = Rect.fromCircle(center: center, radius: outerR);
    final gradient = isActive ? Palette.brassGradient : Palette.steelGradient;

    final gearPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = gradient.createShader(rect);

    final edgePaint = Paint()
      ..color = const Color(0xFF16130F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    for (int i = 0; i < teeth; i++) {
      final double step = (2 * math.pi) / teeth;
      final double a0 = i * step;
      final double a1 = a0 + step * 0.28;
      final double a2 = a0 + step * 0.55;
      final double a3 = a0 + step * 0.82;

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

    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x88000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    canvas.drawPath(path, gearPaint);
    canvas.drawPath(path, edgePaint);

    final glossPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          whiteTint(isActive ? 0.16 : 0.05),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55],
      ).createShader(rect);
    canvas.drawPath(path, glossPaint);

    final grooveR = innerR - 9;
    canvas.drawCircle(
      center,
      grooveR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF1A1713),
    );

    final hubR = innerR - 17;
    canvas.drawCircle(
      center,
      hubR,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.4),
          radius: 1.0,
          colors: [Color(0xFF221F1C), Color(0xFF121110), Color(0xFF0B0A09)],
          stops: [0.0, 0.65, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: hubR)),
    );
    canvas.drawCircle(
      center,
      hubR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = isActive ? const Color(0xFF6E5626) : const Color(0xFF2C2723),
    );

    final rivetBase = Paint()..color = isActive ? const Color(0xFF7A5F2A) : const Color(0xFF2E2A26);
    final rivetHighlight = Paint()..color = isActive ? const Color(0xFFE2C485) : const Color(0xFF4A443E);
    for (int i = 0; i < teeth; i++) {
      final a = (i * 2 * math.pi) / teeth + (math.pi / teeth);
      final rx = center.dx + (innerR - 8) * math.cos(a);
      final ry = center.dy + (innerR - 8) * math.sin(a);
      canvas.drawCircle(Offset(rx, ry), 3.0, rivetBase);
      canvas.drawCircle(Offset(rx - 0.8, ry - 0.8), 1.3, rivetHighlight);
    }
  }

  @override
  bool shouldRepaint(covariant PolishedGearPainter oldDelegate) => oldDelegate.isActive != isActive;
}
