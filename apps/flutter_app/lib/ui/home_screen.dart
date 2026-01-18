import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/websocket_service.dart';
import '../services/clipboard_service.dart';
import '../services/device_service.dart';
import '../services/crypto_service.dart';
import '../services/auth_service.dart';
import '../services/discovery_service.dart';
import '../services/sync_coordinator.dart' hide CryptoService;
import '../services/p2p_service.dart';
import '../core/interfaces/discovery_interface.dart';
import 'pairing_screen.dart';
import 'widgets/status_badge.dart';
import 'widgets/encryption_badge.dart';
import 'widgets/peer_list.dart';
import 'widgets/network_graph.dart';
import 'widgets/sync_indicator.dart';

/// Home Screen with P2P synchronization and network visualization
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final WebSocketService _wsService = WebSocketService();
  final ClipboardService _clipboardService = ClipboardService();
  final DeviceService _deviceService = DeviceService();
  final AuthService _authService = AuthService();
  late final CryptoService _cryptoService;

  final TextEditingController _urlController =
      TextEditingController(text: 'ws://localhost:8080/ws');
  final TextEditingController _messageController = TextEditingController();

  final GlobalKey<NetworkGraphState> _graphKey = GlobalKey<NetworkGraphState>();

  String _connectionStatus = 'Disconnected';
  String _currentClipboard = 'No clipboard data yet';
  String _deviceId = 'calculating...';
  String? _authToken;
  bool _isConnected = false;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  String? _lastSyncedContent;

  @override
  void initState() {
    super.initState();
    _initCrypto();
    _initDevice();
    _startClipboardMonitoring();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      await SyncCoordinator.instance.initialize();
      await SyncCoordinator.instance.startSync();

      SyncCoordinator.instance.onClipboardReceived = (content) {
        if (mounted) {
          setState(() {
            _currentClipboard = content;
          });
          _clipboardService.setClipboard(content);
        }
      };
    } catch (e) {
      debugPrint('Error initializing services: $e');
    }
  }

  Future<void> _initAuth() async {
    try {
      final uri = Uri.parse(_urlController.text);
      final baseUrl = 'http://${uri.host}:${uri.port}';
      final token = await _authService.getOrRegister(baseUrl);
      if (mounted) {
        setState(() {
          _authToken = token;
        });
      }
    } catch (e) {
      debugPrint('Auth initialization failed: $e');
    }
  }

  void _initCrypto() {
    _cryptoService = CryptoService();
  }

  Future<void> _initDevice() async {
    final id = await _deviceService.getDeviceId();
    if (mounted) {
      setState(() {
        _deviceId = id;
      });
    }
  }

  void _startClipboardMonitoring() {
    _clipboardService.startMonitoring();
    _clipboardService.onClipboardChange.listen((text) {
      if (mounted) {
        setState(() {
          _currentClipboard = text;
        });
        if (_isConnected) {
          _triggerSyncAnimation(text);
          _wsService.sendEncrypted(content: text, sender: _deviceId);
        }
        if (SyncCoordinator.instance.isInitialized) {
          _triggerSyncAnimation(text);
          SyncCoordinator.instance.sendClipboard(text);
        }
      }
    });
  }

  void _triggerSyncAnimation(String content) {
    setState(() {
      _isSyncing = true;
    });
    _graphKey.currentState?.playAnimation();
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _lastSyncTime = DateTime.now();
          _lastSyncedContent =
              content.length > 30 ? '${content.substring(0, 30)}...' : content;
        });
      }
    });
  }

  Future<void> _connect() async {
    try {
      await _initAuth();
      _wsService.connect(
        _urlController.text,
        cryptoService: _cryptoService,
        token: _authToken,
      );
      setState(() {
        _connectionStatus = 'Connected (🔐 Encrypted)';
        _isConnected = true;
      });

      _wsService.messages.listen(
        (message) async {
          try {
            final data = jsonDecode(message.toString());
            if (data is Map && data['type'] == 'clipboard') {
              final sender = data['sender'] as String;
              if (sender == _deviceId) return;

              final content =
                  await _wsService.decryptMessage(data as Map<String, dynamic>);
              if (content == null) return;

              if (mounted) {
                _triggerSyncAnimation(content);
                setState(() {
                  _currentClipboard = content;
                });
                _clipboardService.setClipboard(content);
              }
            }
          } catch (e) {
            debugPrint('Error parsing message: $e');
          }
        },
        onError: (error) {
          if (mounted) {
            setState(() {
              _connectionStatus = 'Error: $error';
              _isConnected = false;
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _connectionStatus = 'Disconnected';
              _isConnected = false;
            });
          }
        },
      );
    } catch (e) {
      setState(() {
        _connectionStatus = 'Failed to connect: $e';
        _isConnected = false;
      });
    }
  }

  void _disconnect() {
    _wsService.dispose();
    setState(() {
      _connectionStatus = 'Disconnected';
      _isConnected = false;
    });
  }

  void _sendMessage() {
    if (_messageController.text.isNotEmpty && _isConnected) {
      _triggerSyncAnimation(_messageController.text);
      _wsService.sendEncrypted(
        content: _messageController.text,
        sender: _deviceId,
      );
      _messageController.clear();
    }
    if (_messageController.text.isNotEmpty &&
        SyncCoordinator.instance.isInitialized) {
      _triggerSyncAnimation(_messageController.text);
      SyncCoordinator.instance.sendClipboard(_messageController.text);
      _messageController.clear();
    }
  }

  void _connectToPeer(PeerData peer) {
    final realPeer = DiscoveryService.instance.currentPeers
        .where((p) => p.deviceId == peer.deviceId)
        .firstOrNull;
    if (realPeer != null) {
      P2PService.instance.connectToPeer(realPeer);
    }
  }

  @override
  void dispose() {
    _wsService.dispose();
    _clipboardService.dispose();
    _urlController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncMist'),
        centerTitle: true,
        actions: [
          // StatusBadge with real connection count from P2PService
          StreamBuilder<ConnectionEvent>(
            stream: P2PService.instance.connectionEvents,
            builder: (context, snapshot) {
              final peerCount = P2PService.instance.peerCount;
              return StatusBadge(
                isConnected: _isConnected || peerCount > 0,
                peerCount: peerCount,
              );
            },
          ),
          const SizedBox(width: 8),
          const EncryptionBadge(),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Pair Device',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const PairingScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Network Graph with real peer data
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Network', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 16),
                    Center(
                      child: SizedBox(
                        height: 200,
                        width: 200,
                        child: StreamBuilder<List<PeerInfo>>(
                          stream: DiscoveryService.instance.peers,
                          builder: (context, snapshot) {
                            final peers = snapshot.data ?? [];
                            final networkNodes = [
                              DeviceNode(
                                id: 'self',
                                name: _deviceId.length > 8
                                    ? _deviceId.substring(0, 8)
                                    : _deviceId,
                                isThisDevice: true,
                                isConnected: true,
                              ),
                              ...peers.map((peer) {
                                final isConnected = P2PService
                                    .instance.connectedPeers
                                    .any((p) =>
                                        p.address ==
                                        peer.addresses.firstOrNull);
                                return DeviceNode(
                                  id: peer.deviceId,
                                  name: peer.deviceName,
                                  isThisDevice: false,
                                  isConnected: isConnected,
                                );
                              }),
                            ];
                            return NetworkGraph(
                              key: _graphKey,
                              devices: networkNodes,
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Sync Indicator with real sync events
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: StreamBuilder<SyncEvent>(
                  stream: SyncCoordinator.instance.syncEvents,
                  builder: (context, snapshot) {
                    if (snapshot.hasData) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _graphKey.currentState?.playAnimation();
                      });
                    }
                    final event = snapshot.data;
                    return SyncIndicator(
                      isSyncing: _isSyncing,
                      lastSyncTime: event?.timestamp ?? _lastSyncTime,
                      lastSyncedContent:
                          event?.contentPreview ?? _lastSyncedContent,
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Connection URL TextField
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'WebSocket URL',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
              enabled: !_isConnected,
            ),
            const SizedBox(height: 12),

            // Connect/Disconnect Button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isConnected ? _disconnect : _connect,
                icon: Icon(_isConnected ? Icons.link_off : Icons.link),
                label: Text(_isConnected ? 'Disconnect' : 'Connect'),
              ),
            ),
            const SizedBox(height: 16),

            // Connection Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(
                      _isConnected ? Icons.cloud_done : Icons.cloud_off,
                      color:
                          _isConnected ? Colors.green : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Status', style: theme.textTheme.labelMedium),
                        Text(_connectionStatus,
                            style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Current Clipboard Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.content_paste,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('Current Clipboard',
                            style: theme.textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _currentClipboard,
                        style: theme.textTheme.bodyLarge,
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Nearby Devices Section with StreamBuilder
            StreamBuilder<List<PeerInfo>>(
              stream: DiscoveryService.instance.peers,
              builder: (context, snapshot) {
                final peers = snapshot.data ?? [];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Nearby Devices (${peers.length})',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 200,
                      child: PeerList(
                        peers: peers
                            .map((p) => PeerData(
                                  deviceId: p.deviceId,
                                  deviceName: p.deviceName,
                                  address: p.addresses.isNotEmpty
                                      ? p.addresses.first
                                      : 'Unknown',
                                  port: p.port,
                                  isConnected: P2PService
                                      .instance.connectedPeers
                                      .any((c) =>
                                          c.address == p.addresses.firstOrNull),
                                ))
                            .toList(),
                        onConnect: _connectToPeer,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),

            // Manual Send Section
            Text('Manual Send (Testing)', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _sendMessage,
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _graphKey.currentState?.playAnimation(),
        tooltip: 'Trigger Sync Animation',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}
