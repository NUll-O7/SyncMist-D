import 'dart:async';

import '../../main.dart' show isRustAvailable;
import '../../src/rust/discovery/mdns.dart' as rust_mdns;
import '../../src/rust/frb_generated.dart';

/// Information about a discovered peer device.
class PeerInfo {
  /// Unique identifier for this device.
  final String deviceId;

  /// Human-readable name for this device.
  final String deviceName;

  /// List of network addresses for this device.
  final List<String> addresses;

  /// Port number the device is listening on.
  final int port;

  /// When this device was discovered.
  final DateTime discoveredAt;

  PeerInfo({
    required this.deviceId,
    required this.deviceName,
    required this.addresses,
    required this.port,
    DateTime? discoveredAt,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  /// Create from Rust FFI PeerInfo.
  factory PeerInfo.fromRust(rust_mdns.PeerInfo rustPeer) {
    return PeerInfo(
      deviceId: rustPeer.deviceId,
      deviceName: rustPeer.deviceName,
      addresses: rustPeer.addresses,
      port: rustPeer.port,
      discoveredAt: DateTime.fromMillisecondsSinceEpoch(
        rustPeer.discoveredAt.toInt(),
      ),
    );
  }

  @override
  String toString() => 'PeerInfo($deviceName @ ${addresses.join(", ")}:$port)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerInfo &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Abstract interface for mDNS-based device discovery.
abstract class DiscoveryInterface {
  /// Set to true in tests to use mock instead of real FFI.
  static bool useMock = false;

  /// Register this device on the network for discovery.
  Future<void> register(String deviceId, String deviceName, int port);

  /// Start browsing for other devices on the network.
  Future<void> startBrowsing();

  /// Stop browsing for devices.
  Future<void> stopBrowsing();

  /// Stream of discovered peers. Emits updated list when peers change.
  Stream<List<PeerInfo>> get discoveredPeers;

  /// Get the singleton instance of the discovery service.
  /// Uses mock if:
  /// - useMock is set to true (for testing)
  /// - Rust FFI is not available (fallback mode)
  static DiscoveryInterface get instance {
    if (useMock || !isRustAvailable) {
      return MockDiscovery();
    }
    return RustDiscovery();
  }
}

/// Real Rust FFI implementation of DiscoveryInterface.
/// Uses MdnsDiscovery from flutter_rust_bridge.
class RustDiscovery implements DiscoveryInterface {
  static final RustDiscovery _instance = RustDiscovery._internal();

  factory RustDiscovery() => _instance;

  RustDiscovery._internal();

  rust_mdns.MdnsDiscovery? _mdnsDiscovery;
  bool _isBrowsing = false;
  Timer? _pollTimer;

  final StreamController<List<PeerInfo>> _peersController =
      StreamController<List<PeerInfo>>.broadcast();

  @override
  Future<void> register(String deviceId, String deviceName, int port) async {
    await _ensureInitialized(deviceId, deviceName);

    print(
        '[RustDiscovery] Registering device: $deviceName ($deviceId) on port $port');

    try {
      _mdnsDiscovery!.register(port: port);
      print('[RustDiscovery] Device registered successfully');
    } catch (e) {
      print('[RustDiscovery] Error registering: $e');
      rethrow;
    }
  }

  @override
  Future<void> startBrowsing() async {
    if (_isBrowsing) {
      print('[RustDiscovery] Already browsing');
      return;
    }

    if (_mdnsDiscovery == null) {
      throw StateError('Discovery not initialized. Call register() first.');
    }

    print('[RustDiscovery] Starting network browsing...');

    try {
      _mdnsDiscovery!.startBrowsing();
      _isBrowsing = true;

      // Poll for discovered peers periodically
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        await _pollPeers();
      });

      print('[RustDiscovery] Browsing started');
    } catch (e) {
      print('[RustDiscovery] Error starting browsing: $e');
      rethrow;
    }
  }

  @override
  Future<void> stopBrowsing() async {
    print('[RustDiscovery] Stopping network browsing');

    _pollTimer?.cancel();
    _pollTimer = null;
    _isBrowsing = false;

    if (_mdnsDiscovery != null) {
      _mdnsDiscovery!.stop();
    }

    _peersController.add([]);
  }

  @override
  Stream<List<PeerInfo>> get discoveredPeers => _peersController.stream;

  /// Initialize the Rust library and create MdnsDiscovery.
  Future<void> _ensureInitialized(String deviceId, String deviceName) async {
    if (_mdnsDiscovery == null) {
      await RustLib.init();
      _mdnsDiscovery = rust_mdns.MdnsDiscovery(
        deviceId: deviceId,
        deviceName: deviceName,
      );
      print('[RustDiscovery] Initialized MdnsDiscovery');
    }
  }

  /// Poll for peers from Rust.
  Future<void> _pollPeers() async {
    if (_mdnsDiscovery == null || !_isBrowsing) return;

    try {
      final rustPeers = await _mdnsDiscovery!.getDiscoveredPeers();
      final peers = rustPeers.map((p) => PeerInfo.fromRust(p)).toList();
      _peersController.add(peers);

      if (peers.isNotEmpty) {
        print('[RustDiscovery] Found ${peers.length} peers');
      }
    } catch (e) {
      print('[RustDiscovery] Error polling peers: $e');
    }
  }

  /// Check if currently browsing.
  bool get isBrowsing => _isBrowsing;
}

// ============================================================================
// MOCK IMPLEMENTATION (kept for fallback/testing)
// ============================================================================

class MockDiscovery implements DiscoveryInterface {
  static final MockDiscovery _instance = MockDiscovery._internal();

  factory MockDiscovery() => _instance;

  MockDiscovery._internal();

  bool _isBrowsing = false;

  final StreamController<List<PeerInfo>> _peersController =
      StreamController<List<PeerInfo>>.broadcast();

  final List<PeerInfo> _mockPeers = [];

  @override
  Future<void> register(String deviceId, String deviceName, int port) async {
    print(
        '[MockDiscovery] Registering device: $deviceName ($deviceId) on port $port');
  }

  @override
  Future<void> startBrowsing() async {
    if (_isBrowsing) return;

    print('[MockDiscovery] Starting network browsing...');
    _isBrowsing = true;

    Future.delayed(const Duration(seconds: 1), () {
      if (!_isBrowsing) return;

      _mockPeers.clear();
      _mockPeers.addAll([
        PeerInfo(
          deviceId: 'mock-pc',
          deviceName: 'Windows PC',
          addresses: ['192.168.1.100'],
          port: 9876,
        ),
        PeerInfo(
          deviceId: 'mock-phone',
          deviceName: 'Android Phone',
          addresses: ['192.168.1.101'],
          port: 9876,
        ),
      ]);

      _peersController.add(List.unmodifiable(_mockPeers));
    });
  }

  @override
  Future<void> stopBrowsing() async {
    _isBrowsing = false;
    _mockPeers.clear();
    _peersController.add([]);
  }

  @override
  Stream<List<PeerInfo>> get discoveredPeers => _peersController.stream;

  bool get isBrowsing => _isBrowsing;
}
