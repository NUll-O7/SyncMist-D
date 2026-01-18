import 'dart:async';
import 'dart:typed_data';

import '../../main.dart' show isRustAvailable;
import '../../src/rust/transport/quic.dart';
import '../../src/rust/frb_generated.dart';

/// Abstract interface for P2P transport layer.
///
/// This interface defines the contract for peer-to-peer communication.
abstract class TransportInterface {
  /// Set to true in tests to use mock instead of real FFI.
  static bool useMock = false;

  /// Start listening for incoming connections on the specified port.
  Future<void> startServer({int port = 9876});

  /// Connect to a peer at the given address and port.
  Future<PeerConnection> connectToPeer(String address, int port);

  /// Stream of incoming data from all connected peers.
  Stream<Uint8List> get incomingData;

  /// Disconnect from all peers and stop the server.
  Future<void> disconnect();

  /// Get the singleton instance of the transport.
  /// Uses mock if:
  /// - useMock is set to true (for testing)
  /// - Rust FFI is not available (fallback mode)
  static TransportInterface get instance {
    if (useMock || !isRustAvailable) {
      return MockTransport();
    }
    return RustTransport();
  }
}

/// Represents a connection to a single peer.
class PeerConnection {
  /// Unique identifier for this peer.
  final String peerId;

  /// Network address of the peer.
  final String address;

  /// Port number of the peer.
  final int port;

  /// Whether the connection is currently active.
  bool isConnected;

  /// Reference to the transport for sending data.
  final QuicTransport? _transport;

  /// Controller for incoming data from this peer.
  final StreamController<Uint8List> _dataController =
      StreamController<Uint8List>.broadcast();

  PeerConnection({
    required this.peerId,
    required this.address,
    required this.port,
    this.isConnected = true,
    QuicTransport? transport,
  }) : _transport = transport;

  /// Stream of data received from this peer.
  Stream<Uint8List> get dataStream => _dataController.stream;

  /// Send data to this peer.
  Future<void> send(Uint8List data) async {
    if (!isConnected) {
      throw StateError('Cannot send data: peer is disconnected');
    }
    if (_transport != null) {
      await _transport!.sendData(peerId: peerId, data: data.toList());
      print('[PeerConnection] Sent ${data.length} bytes to $peerId');
    }
  }

  /// Receive data (called by transport when data arrives).
  void receiveData(Uint8List data) {
    if (isConnected) {
      _dataController.add(data);
    }
  }

  /// Close the connection.
  Future<void> close() async {
    isConnected = false;
    if (_transport != null) {
      try {
        await _transport!.disconnect(peerId: peerId);
      } catch (e) {
        print('[PeerConnection] Error disconnecting: $e');
      }
    }
    await _dataController.close();
    print('[PeerConnection] Closed connection to $peerId');
  }
}

/// Real Rust FFI implementation of TransportInterface.
/// Uses QuicTransport from flutter_rust_bridge.
class RustTransport implements TransportInterface {
  static final RustTransport _instance = RustTransport._internal();

  factory RustTransport() => _instance;

  RustTransport._internal();

  QuicTransport? _quicTransport;
  bool _isServerRunning = false;
  final List<PeerConnection> _connections = [];
  final StreamController<Uint8List> _incomingDataController =
      StreamController<Uint8List>.broadcast();

  /// Initialize the Rust library if needed.
  Future<void> _ensureInitialized() async {
    if (_quicTransport == null) {
      await RustLib.init();
      _quicTransport = QuicTransport();
      print('[RustTransport] Initialized QuicTransport');
    }
  }

  @override
  Future<void> startServer({int port = 9876}) async {
    await _ensureInitialized();

    if (_isServerRunning) {
      print('[RustTransport] Server already running');
      return;
    }

    try {
      await _quicTransport!.startServer(port: port);
      _isServerRunning = true;
      print('[RustTransport] Server started on port $port');
    } catch (e) {
      print('[RustTransport] Error starting server: $e');
      rethrow;
    }
  }

  @override
  Future<PeerConnection> connectToPeer(String address, int port) async {
    await _ensureInitialized();

    print('[RustTransport] Connecting to $address:$port...');

    try {
      final peerId =
          await _quicTransport!.connectToPeer(addr: address, port: port);

      final connection = PeerConnection(
        peerId: peerId,
        address: address,
        port: port,
        isConnected: true,
        transport: _quicTransport,
      );

      // Forward peer data to the main incoming stream
      connection.dataStream.listen((data) {
        _incomingDataController.add(data);
      });

      _connections.add(connection);
      print('[RustTransport] Connected to $address:$port as $peerId');

      return connection;
    } catch (e) {
      print('[RustTransport] Error connecting: $e');
      rethrow;
    }
  }

  @override
  Stream<Uint8List> get incomingData => _incomingDataController.stream;

  @override
  Future<void> disconnect() async {
    print('[RustTransport] Disconnecting all peers...');

    for (final connection in _connections) {
      await connection.close();
    }
    _connections.clear();

    if (_quicTransport != null) {
      await _quicTransport!.close();
    }
    _isServerRunning = false;

    print('[RustTransport] All connections closed, server stopped');
  }

  /// Get list of active connections.
  List<PeerConnection> get activeConnections => List.unmodifiable(_connections);

  /// Check if server is running.
  bool get isServerRunning => _isServerRunning;
}

// ============================================================================
// MOCK IMPLEMENTATION (kept for fallback/testing)
// ============================================================================

/// Mock implementation of TransportInterface for development.
class MockTransport implements TransportInterface {
  static final MockTransport _instance = MockTransport._internal();

  factory MockTransport() => _instance;

  MockTransport._internal();

  bool _isServerRunning = false;
  int _serverPort = 9876;
  final List<PeerConnection> _connections = [];
  final StreamController<Uint8List> _incomingDataController =
      StreamController<Uint8List>.broadcast();

  @override
  Future<void> startServer({int port = 9876}) async {
    if (_isServerRunning) {
      print('[MockTransport] Server already running on port $_serverPort');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 50));

    _serverPort = port;
    _isServerRunning = true;
    print('[MockTransport] Server started on port $port');
  }

  @override
  Future<PeerConnection> connectToPeer(String address, int port) async {
    print('[MockTransport] Connecting to $address:$port...');

    await Future.delayed(const Duration(milliseconds: 50));

    final peerId = 'peer-${DateTime.now().millisecondsSinceEpoch}';
    final connection = PeerConnection(
      peerId: peerId,
      address: address,
      port: port,
      isConnected: true,
    );

    connection.dataStream.listen((data) {
      _incomingDataController.add(data);
    });

    _connections.add(connection);
    print('[MockTransport] Connected to $address:$port as $peerId');

    return connection;
  }

  @override
  Stream<Uint8List> get incomingData => _incomingDataController.stream;

  @override
  Future<void> disconnect() async {
    print('[MockTransport] Disconnecting all peers...');

    for (final connection in _connections) {
      await connection.close();
    }
    _connections.clear();
    _isServerRunning = false;

    print('[MockTransport] All connections closed, server stopped');
  }

  List<PeerConnection> get activeConnections => List.unmodifiable(_connections);
  bool get isServerRunning => _isServerRunning;

  void simulateIncomingData(String peerId, Uint8List data) {
    final connection =
        _connections.where((c) => c.peerId == peerId).firstOrNull;
    if (connection != null) {
      print('[MockTransport] Simulating incoming data from $peerId');
      Future.delayed(const Duration(milliseconds: 50), () {
        connection.receiveData(data);
      });
    }
  }
}
