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

class ServerEndpoint {
  final String host;
  final int port;
  ServerEndpoint(this.host, this.port);
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

class _MainVpnScreenState extends State<MainVpnScreen> with SingleTickerProviderStateMixin {
  late AnimationController _gearController;
  
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

  final List<String> gitHubSources = [
    'https://cdn.jsdelivr.net/gh/barry-far/V2ray-config@main/Splitted-By-Protocol/vless.txt',
    'https://cdn.jsdelivr.net/gh/ebrasha/free-v2ray-public-list@main/vless_configs.txt',
    'https://cdn.jsdelivr.net/gh/Delta-Kronecker/V2ray-Config@main/config/protocols/vless.txt',
    'https://cdn.jsdelivr.net/gh/igareck/vpn-configs-for-russia@main/BLACK_VLESS_RUS_mobile.txt',
  ];

  @override
  void initState() {
    super.initState();
    _gearController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );
    _initV2RayEngine();
    _loadStoredData();
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
    super.dispose();
  }

  Future<void> _loadStoredData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      final pinnedList = prefs.getStringList('pinned_vpn_configs') ?? [];
      pinnedConfigs = pinnedList.toSet();

      final saved = prefs.getStringList('custom_vpn_keys') ?? [];
      if (saved.isNotEmpty) {
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

  // Генератор валидной конфигурации по стандарту v2rayNG
  String _buildCleanConfig(String rawConfig) {
    final v2rayURL = FlutterV2ray.parseFromURL(rawConfig);

    // Только чистые валидные IP-адреса для системного VpnService Android
    v2rayURL.dns = {
      "servers": [
        "1.1.1.1",
        "8.8.8.8",
        "1.0.0.1",
        "8.8.4.4"
      ],
      "queryStrategy": "UseIP"
    };

    // Сниффинг строго как в v2rayNG: только http и tls
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

  // Парсер сетевого эндпоинта для быстрого предварительного отсева
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

  // Экспресс-проверка доступности сокета перед тяжелым замером Xray
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

  // Сортировка: закрепленные сверху, далее лучшие по пингу
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

  // Поиск и конвейерный замер
  Future<void> _searchGitHubForKeys() async {
    if (isSearchingGitHub) return;
    setState(() => isSearchingGitHub = true);

    _showToast("Поиск ключей в открытых реестрах...", isSuccess: true);

    List<ServerNode> collectedNodes = [];

    final existingPinned = autoServers.where((s) => s.isPinned).toList();
    collectedNodes.addAll(existingPinned);

    for (final url in gitHubSources) {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 4));
        if (res.statusCode == 200 && res.body.isNotEmpty) {
          final configs = _extractConfigs(res.body);

          for (final config in configs) {
            if (collectedNodes.any((n) => n.rawConfig == config)) continue;

            String title = "Узел ${collectedNodes.length + 1}";
            if (config.contains('#')) {
              try {
                title = Uri.decodeComponent(config.split('#').last).trim();
              } catch (_) {
                title = config.split('#').last;
              }
            }

            final isPinned = pinnedConfigs.contains(config);
            collectedNodes.add(ServerNode(
              name: title.isEmpty ? "Узел ${collectedNodes.length + 1}" : title,
              rawConfig: config,
              ping: -2,
              isPinned: isPinned,
            ));
            if (collectedNodes.length >= 16) break;
          }
        }
      } catch (_) {
        continue;
      }
      if (collectedNodes.length >= 16) break;
    }

    if (collectedNodes.isNotEmpty && mounted) {
      setState(() {
        autoServers = collectedNodes;
        _sortNodes(autoServers);
        selectedIndex = 0;
      });

      _showToast("Получено ${collectedNodes.length} узлов. Тестирование задержки...", isSuccess: true);

      // Двухступенчатый замер: TCP-отсев + честный Xray Real Delay
      await _testNodesPipeline(autoServers);

      // Автоматическое удаление нерабочих незакрепленных узлов
      if (mounted) {
        setState(() {
          autoServers.removeWhere((s) => !s.isPinned && s.ping <= 0);
          _sortNodes(autoServers);
          if (selectedIndex >= autoServers.length) selectedIndex = 0;
        });
        _showToast("Проверка завершена. Активных узлов: ${autoServers.length}", isSuccess: true);
      }
    } else {
      if (mounted) {
        _showToast("Ошибка связи с реестрами GitHub", isSuccess: false);
      }
    }

    if (mounted) setState(() => isSearchingGitHub = false);
  }

  // Конвейер: быстрый параллельный фильтр, затем честный Real Delay
  Future<void> _testNodesPipeline(List<ServerNode> nodes) async {
    List<ServerNode> candidates = [];

    // Шаг 1: Мгновенный TCP-отсев мертвых IP (до 0.9 сек)
    await Future.wait(nodes.map((node) async {
      final reachable = await _fastTcpPreCheck(node.rawConfig);
      if (reachable) {
        candidates.add(node);
      } else {
        if (mounted) setState(() => node.ping = -1);
      }
    }));

    // Шаг 2: Честный замер Real Delay через Xray только для живых серверов
    const int chunkSize = 2;
    for (int i = 0; i < candidates.length; i += chunkSize) {
      if (!mounted) break;
      final end = (i + chunkSize < candidates.length) ? i + chunkSize : candidates.length;
      final chunk = candidates.sublist(i, end);
      await Future.wait(chunk.map((node) => _testNodeRealDelay(node)));
    }
  }

  // Честный замер Real Delay через ядро Xray (по стандарту v2rayNG)
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

    if (mounted) {
      setState(() {
        node.ping = delay;
        _sortNodes(activeList);
      });
    }
  }

  // Выбор сервера с мягким переподключением на лету
  Future<void> _selectAndSwitchServer(int idx) async {
    final activeList = currentTab == 0 ? autoServers : customServers;
    if (activeList.isEmpty || idx >= activeList.length) return;

    final targetNode = activeList[idx];

    // Если соединение активно и выбран другой сервер — выполняем переподключение
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
        await Future.delayed(const Duration(milliseconds: 150));
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

  // Запуск VPN-туннеля
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
          _showToast("VPN активирован: ${node.name}", isSuccess: true);
        }
      } else {
        if (mounted) {
          setState(() => isConnecting = false);
          _gearController.stop();
          _showToast("Разрешение отклонено", isSuccess: false);
        }
      }
    } catch (e) {
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
      _showToast("Список узлов пуст. Нажмите поиск вверху", isSuccess: false);
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
      list.removeWhere((s) => !s.isPinned && s.ping <= 0 && s.ping != -2);
      _sortNodes(list);
      if (selectedIndex >= list.length) selectedIndex = 0;
    });

    final removedCount = before - list.length;
    if (currentTab == 1) {
      _saveCustomKeysToStorage();
    }

    if (removedCount > 0) {
      _showToast("Удалено нерабочих узлов: $removedCount", isSuccess: true);
    } else {
      _showToast("Все узлы в списке активны", isSuccess: true);
    }
  }

  void _showToast(String message, {required bool isSuccess}) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
        ),
        backgroundColor: isSuccess ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  void _showAddKeyDialog() {
    final nameController = TextEditingController();
    final configController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1B1917),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFC5A059), width: 1.2),
        ),
        title: Row(
          children: const [
            Icon(Icons.add_link, color: Color(0xFFC5A059)),
            SizedBox(width: 10),
            Text("Добавить свой ключ", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF3B352E))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC5A059))),
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
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF3B352E))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFC5A059))),
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
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC5A059)),
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
            child: const Text("ДОБАВИТЬ", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
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
          side: const BorderSide(color: Color(0xFFC5A059), width: 1.2),
        ),
        title: Row(
          children: const [
            Icon(Icons.info_outline, color: Color(0xFFC5A059)),
            SizedBox(width: 10),
            Text("Архитектура системы", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                "Принципы работы Scale VPN:",
                style: TextStyle(color: Color(0xFFC5A059), fontWeight: FontWeight.bold, fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                "1. Сбор реестров GitHub:\n"
                "Опрос открытых баз VLESS Reality и Shadowsocks каждые 15 минут.\n\n"
                "2. Честный замер Real Delay:\n"
                "Опрос узлов через ядро Xray до gstatic.com/generate_204 по стандарту v2rayNG с автоматической сортировкой.\n\n"
                "3. Чистый DNS и маршрутизация:\n"
                "Штатная конфигурация DNS 1.1.1.1 и 8.8.8.8 со сниффингом TLS/HTTP без дедлоков видеопотоков YouTube.",
                style: TextStyle(color: Color(0xFFD6D3D1), fontSize: 12.5, height: 1.45),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ЗАКРЫТЬ", style: TextStyle(color: Color(0xFFC5A059), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildPingBadge(int ping) {
    if (ping == -2) {
      return const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFFC5A059)),
      );
    }
    if (ping <= 0) {
      return const Text(
        "Таймаут",
        style: TextStyle(color: Color(0xFFE53935), fontSize: 11, fontWeight: FontWeight.bold),
      );
    }
    return Text(
      "$ping ms",
      style: const TextStyle(color: Color(0xFF66BB6A), fontSize: 11, fontWeight: FontWeight.bold),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeList = currentTab == 0 ? autoServers : customServers;
    final activeNode = activeList.isNotEmpty && selectedIndex < activeList.length ? activeList[selectedIndex] : null;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F1D1A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFC5A059), width: 1.2),
                        ),
                        child: const Icon(Icons.security, color: Color(0xFFC5A059), size: 18),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            "SCALE VPN",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                          Text(
                            "GitHub Key Engine",
                            style: TextStyle(color: Color(0xFF8C827A), fontSize: 10),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.cleaning_services_outlined, color: Color(0xFFC5A059), size: 20),
                        tooltip: "Удалить нерабочие ключи",
                        onPressed: _purgeDeadNodes,
                      ),
                      IconButton(
                        icon: const Icon(Icons.help_outline, color: Color(0xFFC5A059), size: 22),
                        tooltip: "О системе",
                        onPressed: _showInfoDialog,
                      ),
                      IconButton(
                        icon: isSearchingGitHub
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(color: Color(0xFFC5A059), strokeWidth: 2),
                              )
                            : const Icon(Icons.sync, color: Color(0xFFC5A059), size: 22),
                        tooltip: "Искать ключи на GitHub",
                        onPressed: isSearchingGitHub ? null : _searchGitHubForKeys,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Spacer(),

            // ЦЕНТРАЛЬНАЯ КНОПКА ПОДКЛЮЧЕНИЯ
            GestureDetector(
              onTap: _handleToggle,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 210,
                    height: 210,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: isConnected ? const Color(0x4DFF9800) : Colors.transparent,
                          blurRadius: 40,
                          spreadRadius: 10,
                        ),
                      ],
                    ),
                  ),
                  RotationTransition(
                    turns: _gearController,
                    child: CustomPaint(
                      size: const Size(190, 190),
                      painter: PolishedGearPainter(isActive: isConnected),
                    ),
                  ),
                  Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF141210),
                      border: Border.all(
                        color: isConnected ? const Color(0xFFFF9800) : const Color(0xFF4A443E),
                        width: 2.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isConnected ? const Color(0x80FF9800) : Colors.black87,
                          blurRadius: isConnected ? 16 : 4,
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.power_settings_new,
                      size: 38,
                      color: isConnected
                          ? const Color(0xFFFFB74D)
                          : (_isReconnecting || isConnecting ? const Color(0xFFC5A059) : const Color(0xFF6B635B)),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            Text(
              isConnected
                  ? "СОЕДИНЕНИЕ АКТИВНО"
                  : (_isReconnecting
                      ? "ПЕРЕПОДКЛЮЧЕНИЕ..."
                      : (isConnecting ? "ПОДКЛЮЧЕНИЕ..." : "ОТКЛЮЧЕНО")),
              style: TextStyle(
                color: isConnected
                    ? const Color(0xFFFFB74D)
                    : (_isReconnecting || isConnecting ? const Color(0xFFC5A059) : const Color(0xFF9E948A)),
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),

            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF181614),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF38332E)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed, size: 15, color: isConnected ? const Color(0xFFC5A059) : const Color(0xFF6B635B)),
                  const SizedBox(width: 8),
                  const Text("Пинг: ", style: TextStyle(color: Color(0xFFD6D3D1), fontSize: 11)),
                  activeNode != null
                      ? _buildPingBadge(activeNode.ping)
                      : const Text("—", style: TextStyle(color: Color(0xFF8C827A), fontSize: 11)),
                ],
              ),
            ),

            const Spacer(),

            // НИЖНЯЯ ПАНЕЛЬ С СЕРВЕРАМИ GITHUB
            Container(
              height: 240,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              decoration: const BoxDecoration(
                color: Color(0xFF13110F),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                border: Border(top: BorderSide(color: Color(0xFF292420), width: 1.2)),
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
                          IconButton(
                            icon: const Icon(Icons.cleaning_services, color: Color(0xFFC5A059), size: 18),
                            tooltip: "Очистить нерабочие узлы",
                            onPressed: _purgeDeadNodes,
                          ),
                          if (currentTab == 1)
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline, color: Color(0xFFC5A059), size: 22),
                              tooltip: "Добавить ключ",
                              onPressed: _showAddKeyDialog,
                            ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  Expanded(
                    child: activeList.isEmpty
                        ? Center(
                            child: isSearchingGitHub
                                ? const CircularProgressIndicator(color: Color(0xFFC5A059))
                                : TextButton.icon(
                                    icon: const Icon(Icons.search, color: Color(0xFFC5A059), size: 16),
                                    label: const Text("Найти рабочие ключи на GitHub", style: TextStyle(color: Color(0xFFC5A059), fontSize: 12)),
                                    onPressed: _searchGitHubForKeys,
                                  ),
                          )
                        : ListView.builder(
                            itemCount: activeList.length,
                            itemBuilder: (context, idx) {
                              final item = activeList[idx];
                              final isCurrent = idx == selectedIndex;
                              return GestureDetector(
                                onTap: () => _selectAndSwitchServer(idx),
                                child: Container(
                                  margin: const EdgeInsets.only(bottom: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: isCurrent ? const Color(0xFF24201C) : const Color(0xFF1A1815),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isCurrent ? const Color(0xFFC5A059) : const Color(0xFF2E2924),
                                      width: isCurrent ? 1.2 : 0.8,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 8,
                                              height: 8,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: item.isPinned
                                                    ? const Color(0xFFFF9800)
                                                    : (isCurrent ? const Color(0xFFC5A059) : const Color(0xFF5A524A)),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            if (item.isPinned)
                                              const Padding(
                                                padding: EdgeInsets.only(right: 6),
                                                child: Icon(Icons.push_pin, size: 13, color: Color(0xFFFF9800)),
                                              ),
                                            Expanded(
                                              child: Text(
                                                item.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isCurrent ? Colors.white : const Color(0xFFD6D3D1),
                                                  fontSize: 12,
                                                  fontWeight: (isCurrent || item.isPinned) ? FontWeight.bold : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildPingBadge(item.ping),
                                          const SizedBox(width: 4),
                                          IconButton(
                                            icon: Icon(
                                              item.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                                              size: 16,
                                              color: item.isPinned ? const Color(0xFFFF9800) : const Color(0xFF8C827A),
                                            ),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            tooltip: item.isPinned ? "Открепить узел" : "Закрепить узел вверху",
                                            onPressed: () => _togglePin(item),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.network_check, size: 16, color: Color(0xFFC5A059)),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            tooltip: "Замерить задержку",
                                            onPressed: () => _testNodeRealDelay(item),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.copy, size: 15, color: Color(0xFF8C827A)),
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
                                                  customServers.removeAt(idx);
                                                  if (selectedIndex >= customServers.length) selectedIndex = 0;
                                                });
                                                _saveCustomKeysToStorage();
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
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(String title, int index) {
    final isSelected = currentTab == index;
    return GestureDetector(
      onTap: () => setState(() {
        currentTab = index;
        selectedIndex = 0;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF2B251E) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFFC5A059) : const Color(0xFF332E29),
            width: 1,
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? const Color(0xFFC5A059) : const Color(0xFF8C827A),
            fontSize: 11.5,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class PolishedGearPainter extends CustomPainter {
  final bool isActive;

  PolishedGearPainter({required this.isActive});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerR = size.width / 2 - 4;
    final innerR = outerR - 14;
    const teeth = 12;

    final brassColor = isActive ? const Color(0xFFC5A059) : const Color(0xFF4A443E);
    final darkEdge = const Color(0xFF1F1D1A);

    final gearPaint = Paint()..color = brassColor..style = PaintingStyle.fill;
    final edgePaint = Paint()..color = darkEdge..style = PaintingStyle.stroke..strokeWidth = 2;

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

    canvas.drawPath(path, gearPaint);
    canvas.drawPath(path, edgePaint);

    final rimR = innerR - 16;
    canvas.drawCircle(center, rimR, Paint()..color = const Color(0xFF141210));
    canvas.drawCircle(center, rimR, edgePaint);

    final rivetPaint = Paint()..color = isActive ? const Color(0xFF8C7038) : const Color(0xFF332F2B);
    for (int i = 0; i < teeth; i++) {
      final a = (i * 2 * math.pi) / teeth + (math.pi / teeth);
      final rx = center.dx + (innerR - 8) * math.cos(a);
      final ry = center.dy + (innerR - 8) * math.sin(a);
      canvas.drawCircle(Offset(rx, ry), 2.0, rivetPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PolishedGearPainter oldDelegate) => oldDelegate.isActive != isActive;
}
