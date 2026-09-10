import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

// ПАЛИТРА ИНДУСТРИАЛЬНОГО СТИМПАНКА
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

// Прозрачность без устаревшего API withOpacity: собираем цвет по каналам
Color tint(int r, int g, int b, double fraction) {
  final double f = fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
  return Color.fromARGB((f * 255).round(), r, g, b);
}

Color amberTint(double fraction) => tint(0xFF, 0x98, 0x00, fraction);
Color brassTint(double fraction) => tint(0xC5, 0xA0, 0x59, fraction);
Color whiteTint(double fraction) => tint(0xFF, 0xFF, 0xFF, fraction);

class ServerEndpoint {
  final String host;
  final int port;
  ServerEndpoint(this.host, this.port);

  @override
  String toString() => '$host:$port';
}

class ServerNode {
  final String name;
  final String rawConfig;
  int ping; // -2: замер, -1: таймаут, >0: миллисекунды
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

  int currentTab = 0; // 0 - GitHub, 1 - Мои ключи
  int selectedIndex = 0;

  List<ServerNode> autoServers = [];
  List<ServerNode> customServers = [];
  Set<String> pinnedConfigs = {};

  // ЧЕРНЫЙ СПИСОК: ключ эндпоинта -> метка времени внесения (millisSinceEpoch)
  final Map<String, int> _deadKeys = {};
  static const int _deadKeyTtlMs = 6 * 60 * 60 * 1000; // 6 часов
  static const int _deadKeyLimit = 900;

  // РОТАЦИЯ И ПРИОРИТЕТЫ
  int _priorityOffset = 0;
  int _generalOffset = 0;
  static const int _batchSize = 18;
  static const int _maxAutoRetries = 3;

  final math.Random _random = math.Random();

  // 1. ПРИОРИТЕТНЫЕ РЕПОЗИТОРИИ ДЛЯ РФ (igareck & topics/free-vpn-russia)
  // Протестированы на обход ТСПУ, белые списки и Reality
  final List<String> priorityRussiaSources = [
    'https://cdn.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_VLESS_RUS_mobile.txt',
    'https://cdn.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_VLESS_RUS.txt',
    'https://cdn.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/Vless-Reality-White-Lists-Rus-Mobile.txt',
    'https://cdn.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_SS+All_RUS.txt',
    'https://raw.githubusercontent.com/igareck/vpn-configs-for-russia/main/BLACK_VLESS_RUS_mobile.txt',
    'https://cdn.jsdelivr.net/gh/AvenCores/goida-vpn-configs@main/vless.txt',
    'https://cdn.jsdelivr.net/gh/kort0881/vpn-vless-configs-russia@main/githubmirror/clean/vless.txt',
    'https://cdn.jsdelivr.net/gh/kort0881/vpn-vless-configs-russia@main/githubmirror/ru-sni/vless_ru.txt',
    'https://cdn.jsdelivr.net/gh/hiztin/VLESS-PO-GRIBI@main/vless.txt',
    'https://cdn.jsdelivr.net/gh/FLAT447/v2ray-lists@main/vless.txt',
  ];

  // 2. РЕЗЕРВНЫЕ МЕЖДУНАРОДНЫЕ ЗЕРКАЛА (VLESS Reality / Shadowsocks)
  final List<String> generalSources = [
    'https://cdn.jsdelivr.net/gh/barry-far/V2ray-config@main/Splitted-By-Protocol/vless.txt',
    'https://cdn.jsdelivr.net/gh/barry-far/V2ray-config@main/Splitted-By-Protocol/ss.txt',
    'https://cdn.jsdelivr.net/gh/ebrasha/free-v2ray-public-list@main/vless_configs.txt',
    'https://cdn.jsdelivr.net/gh/Delta-Kronecker/V2ray-Config@main/config/protocols/vless.txt',
    'https://cdn.jsdelivr.net/gh/Delta-Kronecker/V2ray-Config@main/config/protocols/shadowsocks.txt',
    'https://cdn.jsdelivr.net/gh/mahdibland/V2RayAggregator@master/sub/sub_merge.txt',
    'https://cdn.jsdelivr.net/gh/Epodonios/v2ray-configs@main/Splitted-By-Protocol/vless.txt',
    'https://cdn.jsdelivr.net/gh/Epodonios/v2ray-configs@main/Splitted-By-Protocol/ss.txt',
    'https://cdn.jsdelivr.net/gh/soroushmirzaei/telegram-configs-collector@main/protocols/vless',
    'https://cdn.jsdelivr.net/gh/soroushmirzaei/telegram-configs-collector@main/protocols/shadowsocks',
    'https://cdn.jsdelivr.net/gh/MhdiTaheri/V2rayCollector@main/sub/vless',
  ];

  List<String> get gitHubSources => [...priorityRussiaSources, ...generalSources];

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchGitHubForKeys());
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

  // ХРАНИЛИЩЕ

  Future<void> _loadStoredData() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final pinnedList = prefs.getStringList('pinned_vpn_configs') ?? [];
      pinnedConfigs = pinnedList.toSet();

      _priorityOffset = prefs.getInt('priority_rotation_offset') ?? 0;
      _generalOffset = prefs.getInt('general_rotation_offset') ?? 0;

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

  Future<void> _saveRotationOffset() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('priority_rotation_offset', _priorityOffset);
      await prefs.setInt('general_rotation_offset', _generalOffset);
      await prefs.setInt('rotation_offset', _priorityOffset);
    } catch (_) {}
  }

  Future<void> _saveDeadKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;

      _deadKeys.removeWhere((key, ts) => now - ts >= _deadKeyTtlMs);

      if (_deadKeys.length > _deadKeyLimit) {
        final sorted = _deadKeys.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        final trimmed = sorted.take(_deadKeyLimit).toList();
        _deadKeys
          ..clear()
          ..addEntries(trimmed);
      }

      final list = _deadKeys.entries.map((e) => "${e.key}|${e.value}").toList();
      await prefs.setStringList('dead_endpoints', list);
    } catch (_) {}
  }

  // ЧЕРНЫЙ СПИСОК

  String _blacklistKey(String rawConfig) {
    final ep = _parseEndpoint(rawConfig);
    if (ep != null) return ep.toString();
    return rawConfig.split('#').first.trim();
  }

  bool _isBlacklisted(String rawConfig) {
    final key = _blacklistKey(rawConfig);
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
    _deadKeys[_blacklistKey(rawConfig)] = DateTime.now().millisecondsSinceEpoch;
  }

  void _markAlive(String rawConfig) {
    _deadKeys.remove(_blacklistKey(rawConfig));
  }

  // КОНФИГУРАЦИЯ ЯДРА (DNS и сниффинг по эталону v2rayNG)

  String _buildCleanConfig(String rawConfig) {
    final v2rayURL = FlutterV2ray.parseFromURL(rawConfig);

    v2rayURL.dns = {
      "servers": [
        "1.1.1.1",
        "8.8.8.8",
        "1.0.0.1",
        "8.8.4.4"
      ],
      "queryStrategy": "UseIP"
    };

    try {
      v2rayURL.inbound['sniffing'] = {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": false
      };
    } catch (_) {}

    final Map<String, dynamic> configMap = jsonDecode(v2rayURL.getFullConfiguration());
    return jsonEncode(configMap);
  }

  ServerEndpoint? _parseEndpoint(String rawConfig) {
    try {
      final uri = Uri.tryParse(rawConfig);
      if (uri != null && uri.host.isNotEmpty && uri.port > 0) {
        return ServerEndpoint(uri.host, uri.port);
      }
    } catch (_) {}

    try {
      final ipv6Reg = RegExp(r'@\[([a-fA-F0-9:]+)\]:(\d+)');
      final match = ipv6Reg.firstMatch(rawConfig);
      if (match != null) {
        return ServerEndpoint(match.group(1)!, int.parse(match.group(2)!));
      }
    } catch (_) {}

    try {
      final reg = RegExp(r'@([a-zA-Z0-9\.\-]+):(\d+)');
      final match = reg.firstMatch(rawConfig);
      if (match != null) {
        return ServerEndpoint(match.group(1)!, int.parse(match.group(2)!));
      }
    } catch (_) {}

    if (rawConfig.startsWith('ss://')) {
      try {
        final body = rawConfig.substring(5).split('#').first;
        if (body.contains('@')) {
          final hostPort = body.split('@').last.split(':');
          return ServerEndpoint(hostPort[0], int.tryParse(hostPort[1]) ?? 443);
        } else {
          String b64 = body;
          while (b64.length % 4 != 0) {
            b64 += '=';
          }
          final decoded = utf8.decode(base64.decode(b64));
          if (decoded.contains('@')) {
            final hostPort = decoded.split('@').last.split(':');
            return ServerEndpoint(hostPort[0], int.tryParse(hostPort[1]) ?? 443);
          }
        }
      } catch (_) {}
    }

    return null;
  }

  Future<bool> _fastTcpPreCheck(String rawConfig) async {
    final ep = _parseEndpoint(rawConfig);
    if (ep == null) return false;
    try {
      final socket = await Socket.connect(ep.host, ep.port, timeout: const Duration(milliseconds: 900));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
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

    try {
      String cleaned = rawData.replaceAll(RegExp(r'\s+'), '');
      while (cleaned.length % 4 != 0) {
        cleaned += '=';
      }
      final decoded = utf8.decode(base64.decode(cleaned));
      if (decoded.contains('vless://') || decoded.contains('ss://')) {
        text = decoded;
      }
    } catch (_) {}

    final lines = text.split(RegExp(r'[\r\n]+'));
    for (var line in lines) {
      line = line.trim();
      if (line.startsWith('vless://') || line.startsWith('ss://')) {
        results.add(line);
      }
    }
    return results;
  }

  // СБОР УЗЛОВ: ПРЕОБЛАДАЮЩИЙ ОПРОС igareck И topics/free-vpn-russia С РЕЗЕРВОМ

  Future<void> _searchGitHubForKeys() async {
    if (isSearchingGitHub) return;
    setState(() => isSearchingGitHub = true);

    _showToast("Синхронизация узлов: опрос реестров РФ и зеркал", isSuccess: true);

    try {
      await _runDiscoveryCycle(attempt: 0);
    } catch (_) {
      if (mounted) _showToast("Ошибка связи с реестрами GitHub", isSuccess: false);
    } finally {
      await _saveDeadKeys();
      await _saveRotationOffset();
      if (mounted) setState(() => isSearchingGitHub = false);
    }
  }

  Future<Map<String, List<String>>> _fetchPool() async {
    // 1. Формируем пачку приоритетных источников (РФ / igareck / topics/free-vpn-russia)
    final priorityBatch = <String>[];
    final pTotal = priorityRussiaSources.length;
    for (int i = 0; i < 4; i++) {
      priorityBatch.add(priorityRussiaSources[(_priorityOffset + i) % pTotal]);
    }

    // 2. Формируем пачку общих международных зеркал для разнообразия и отказоустойчивости
    final generalBatch = <String>[];
    final gTotal = generalSources.length;
    for (int i = 0; i < 3; i++) {
      generalBatch.add(generalSources[(_generalOffset + i) % gTotal]);
    }

    final priorityFutures = priorityBatch.map((url) async {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          return _extractConfigs(res.body);
        }
      } catch (_) {}
      return <String>[];
    });

    final generalFutures = generalBatch.map((url) async {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          return _extractConfigs(res.body);
        }
      } catch (_) {}
      return <String>[];
    });

    final priorityResults = await Future.wait(priorityFutures);
    final generalResults = await Future.wait(generalFutures);

    final priorityPool = <String>[];
    final seenPriority = <String>{};
    for (final list in priorityResults) {
      for (final cfg in list) {
        if (seenPriority.add(cfg)) priorityPool.add(cfg);
      }
    }

    final generalPool = <String>[];
    final seenGeneral = <String>{};
    for (final list in generalResults) {
      for (final cfg in list) {
        if (!seenPriority.contains(cfg) && seenGeneral.add(cfg)) {
          generalPool.add(cfg);
        }
      }
    }

    return {
      'priority': priorityPool,
      'general': generalPool,
    };
  }

  Future<void> _runDiscoveryCycle({required int attempt}) async {
    final pools = await _fetchPool();
    final priorityList = pools['priority'] ?? [];
    final generalList = pools['general'] ?? [];

    if (priorityList.isEmpty && generalList.isEmpty) {
      if (attempt < _maxAutoRetries) {
        _priorityOffset = (_priorityOffset + 3) % priorityRussiaSources.length;
        _generalOffset = (_generalOffset + 3) % generalSources.length;
        if (mounted) _showToast("Поиск альтернативных узлов...", isSuccess: true);
        await Future.delayed(const Duration(milliseconds: 400));
        return _runDiscoveryCycle(attempt: attempt + 1);
      }
      if (mounted) _showToast("Реестры GitHub недоступны", isSuccess: false);
      return;
    }

    // Отсекаем черный список
    final cleanPriority = priorityList.where((c) => !_isBlacklisted(c)).toList();
    final cleanGeneral = generalList.where((c) => !_isBlacklisted(c)).toList();

    final workingPriority = cleanPriority.isNotEmpty ? cleanPriority : priorityList;
    final workingGeneral = cleanGeneral.isNotEmpty ? cleanGeneral : generalList;

    // Перемешивание: каждый поиск выдает свежую выборку, а не первые строки файла
    workingPriority.shuffle(_random);
    workingGeneral.shuffle(_random);

    final collectedNodes = <ServerNode>[];
    collectedNodes.addAll(autoServers.where((s) => s.isPinned));

    // Преобладающая квота для качественных РФ реестров (70% выборки: ~13 узлов)
    const int priorityQuota = 13;
    final priorityPick = workingPriority.take(priorityQuota).toList();

    // Дополняем резервными зеркалами до размера пакета _batchSize (18 узлов)
    final remainingCount = _batchSize - collectedNodes.length - priorityPick.length;
    final generalPick = workingGeneral.take(math.max(0, remainingCount)).toList();

    // Балансировка: если одного пула не хватило, добираем из второго
    final combinedConfigs = <String>[...priorityPick, ...generalPick];
    if (combinedConfigs.length < (_batchSize - collectedNodes.length)) {
      for (final c in workingPriority) {
        if (combinedConfigs.length >= (_batchSize - collectedNodes.length)) break;
        if (!combinedConfigs.contains(c)) combinedConfigs.add(c);
      }
      for (final c in workingGeneral) {
        if (combinedConfigs.length >= (_batchSize - collectedNodes.length)) break;
        if (!combinedConfigs.contains(c)) combinedConfigs.add(c);
      }
    }

    for (final config in combinedConfigs) {
      if (collectedNodes.length >= _batchSize) break;
      if (collectedNodes.any((n) => n.rawConfig == config)) continue;

      String title = "Узел ${collectedNodes.length + 1}";
      if (config.contains('#')) {
        try {
          title = Uri.decodeComponent(config.split('#').last).trim();
        } catch (_) {
          title = config.split('#').last;
        }
      }
      if (title.isEmpty) title = "Узел ${collectedNodes.length + 1}";
      if (title.length > 42) title = title.substring(0, 42);

      collectedNodes.add(ServerNode(
        name: title,
        rawConfig: config,
        ping: -2,
        isPinned: pinnedConfigs.contains(config),
      ));
    }

    if (!mounted) return;

    setState(() {
      autoServers = collectedNodes;
      _sortNodes(autoServers);
      selectedIndex = 0;
    });

    _showToast("Получено узлов: ${collectedNodes.length}. Замер задержки", isSuccess: true);

    await _testNodesPipeline(autoServers);

    if (!mounted) return;

    setState(() {
      for (final node in autoServers) {
        if (!node.isPinned && node.ping <= 0 && node.ping != -2) {
          _markDead(node.rawConfig);
        }
      }
      autoServers.removeWhere((s) => !s.isPinned && s.ping <= 0);
      _sortNodes(autoServers);
      if (selectedIndex >= autoServers.length) selectedIndex = 0;
    });

    // ЗАЩИТНЫЙ АЛГОРИТМ: пустой список автоматически запускает поиск по следующим смещениям
    if (autoServers.isEmpty && attempt < _maxAutoRetries) {
      _priorityOffset = (_priorityOffset + 2) % priorityRussiaSources.length;
      _generalOffset = (_generalOffset + 2) % generalSources.length;
      _showToast("Поиск альтернативных узлов...", isSuccess: true);
      await Future.delayed(const Duration(milliseconds: 300));
      return _runDiscoveryCycle(attempt: attempt + 1);
    }

    if (autoServers.isEmpty) {
      _showToast("Стабильных узлов не найдено. Повторите синхронизацию", isSuccess: false);
    } else {
      _priorityOffset = (_priorityOffset + 2) % priorityRussiaSources.length;
      _generalOffset = (_generalOffset + 1) % generalSources.length;
      _showToast("Проверка завершена. Активных узлов: ${autoServers.length}", isSuccess: true);
    }
  }

  Future<void> _testNodesPipeline(List<ServerNode> nodes) async {
    List<ServerNode> candidates = [];

    await Future.wait(nodes.map((node) async {
      final reachable = await _fastTcpPreCheck(node.rawConfig);
      if (reachable) {
        candidates.add(node);
      } else {
        if (mounted) setState(() => node.ping = -1);
      }
    }));

    const int chunkSize = 2;
    for (int i = 0; i < candidates.length; i += chunkSize) {
      if (!mounted) break;
      final end = (i + chunkSize < candidates.length) ? i + chunkSize : candidates.length;
      final chunk = candidates.sublist(i, end);
      await Future.wait(chunk.map((node) => _testNodeRealDelay(node)));
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
            .timeout(const Duration(milliseconds: 2500), onTimeout: () => -1);
      } else {
        final cleanConfig = _buildCleanConfig(node.rawConfig);
        delay = await flutterV2ray
            .getServerDelay(
              config: cleanConfig,
              url: 'https://www.gstatic.com/generate_204',
            )
            .timeout(const Duration(milliseconds: 2500), onTimeout: () => -1);
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

  // УПРАВЛЕНИЕ ТУННЕЛЕМ

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
        await Future.delayed(const Duration(milliseconds: 180));
        if (mounted) setState(() => _isReconnecting = false);
        await _startTunnel(targetNode);
      } catch (_) {
        if (mounted) {
          setState(() {
            isConnecting = false;
            isConnected = false;
          });
          _gearController.stop();
          _showToast("Ошибка переподключения", isSuccess: false);
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

        await flutterV2ray.startV2Ray(
          remark: node.name,
          config: cleanConfig,
          proxyOnly: false,
          bypassSubnets: null,
          notificationDisconnectButtonName: "ОТКЛЮЧИТЬ",
        );

        if (mounted) {
          _showToast("Соединение активно: ${node.name}", isSuccess: true);
        }
      } else {
        if (mounted) {
          setState(() => isConnecting = false);
          _gearController.stop();
          _showToast("Разрешение отклонено", isSuccess: false);
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => isConnecting = false);
        _gearController.stop();
        _showToast("Ошибка конфигурации узла", isSuccess: false);
      }
    }
  }

  void _handleToggle() async {
    final activeList = currentTab == 0 ? autoServers : customServers;
    if (activeList.isEmpty) {
      _showToast("Список узлов пуст. Запустите синхронизацию", isSuccess: false);
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

      _showToast("Соединение разорвано", isSuccess: false);
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
      _showToast("Удалено нерабочих узлов: $removedCount", isSuccess: true);
    } else {
      _showToast("Все узлы в списке активны", isSuccess: true);
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
        duration: const Duration(milliseconds: 2400),
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
            Text("Архитектура системы",
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Принципы работы Scale VPN:",
                style: TextStyle(color: Palette.brass, fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              const Text(
                "1. Сбор реестров GitHub:\n"
                "Преобладающий опрос проверенных российских реестров (igareck & topics/free-vpn-russia) с автоматической ротацией и резервными зеркалами.\n\n"
                "2. Черный список:\n"
                "Эндпоинты с подтвержденным таймаутом отсекаются до замера и хранятся 6 часов.\n\n"
                "3. Честный замер Real Delay:\n"
                "Опрос узлов через ядро Xray до gstatic.com/generate_204 по стандарту v2rayNG с автоматической сортировкой.\n\n"
                "4. Чистый DNS и маршрутизация:\n"
                "Штатная конфигурация DNS 1.1.1.1 и 8.8.8.8 со сниффингом TLS/HTTP без дедлоков видеопотоков YouTube.",
                style: TextStyle(color: Color(0xFFD6D3D1), fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 10),
              Text(
                "Записей в черном списке: ${_deadKeys.length}\nПриоритет (РФ): смещение $_priorityOffset\nРезерв: смещение $_generalOffset",
                style: const TextStyle(color: Palette.textMuted, fontSize: 11.5, height: 1.4),
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

  // ВИЗУАЛЬНЫЕ ЭЛЕМЕНТЫ

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
              const SizedBox(height: 22),
              _buildStatusLabel(),
              const SizedBox(height: 12),
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
                    "GITHUB KEY ENGINE",
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
                icon: Icons.help_outline,
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
        : (_isReconnecting ? "ПЕРЕПОДКЛЮЧЕНИЕ..." : (isConnecting ? "ПОДКЛЮЧЕНИЕ..." : "ОТКЛЮЧЕНО"));

    final Color color = isConnected
        ? Palette.amberSoft
        : (_isReconnecting || isConnecting ? Palette.brass : const Color(0xFF9E948A));

    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 2.6,
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
      height: 252,
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
                  _buildTabButton("GitHub Реестр", 0),
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
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(color: Palette.brass, strokeWidth: 2.2),
            ),
            SizedBox(height: 12),
            Text("Синхронизация узлов",
                style: TextStyle(color: Palette.textMuted, fontSize: 11.5, letterSpacing: 1)),
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
        label: const Text("Найти рабочие узлы в реестрах GitHub",
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

// НЕПОДВИЖНОЕ ВНЕШНЕЕ КОЛЬЦО-БЕЗЕЛЬ С НАСЕЧКОЙ
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

// ШЛИФОВАННАЯ ЛАТУННАЯ ШЕСТЕРНЯ
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

    // Тень под корпусом шестерни
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x88000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    canvas.drawPath(path, gearPaint);
    canvas.drawPath(path, edgePaint);

    // Верхний блик шлифовки
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

    // Внутренняя проточка
    final grooveR = innerR - 9;
    canvas.drawCircle(
      center,
      grooveR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFF1A1713),
    );

    // Ступица
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

    // Заклепки
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
