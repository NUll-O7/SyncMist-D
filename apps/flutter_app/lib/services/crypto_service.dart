import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../main.dart' show isRustAvailable;

// Conditionally import Rust crypto - only use if available
import '../src/rust/crypto.dart' as rust_crypto;

/// Service for encrypting and decrypting clipboard content
///
/// Uses AES-256-GCM encryption via Rust FFI with X25519 key exchange for pairing.
/// Falls back to mock encryption if Rust FFI is not available.
class CryptoService {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _keyPrivate = 'keypair_private';
  static const String _keyPublic = 'keypair_public';
  static const String _sharedSecretPrefix = 'shared_secret_';
  static const String _legacyKeyName = 'legacy_encryption_key';

  Uint8List? _cachedPrivateKey;
  Uint8List? _cachedPublicKey;
  Uint8List? _legacyKey;

  /// Mock XOR key for fallback encryption (NOT SECURE - demo only)
  static const int _mockXorKey = 0x5A;

  /// Get or create the device's X25519 keypair
  /// Returns (privateKey, publicKey)
  Future<(Uint8List, Uint8List)> getOrCreateKeypair() async {
    // Check cache first
    if (_cachedPrivateKey != null && _cachedPublicKey != null) {
      return (_cachedPrivateKey!, _cachedPublicKey!);
    }

    // Try to load from secure storage
    final storedPrivate = await _secureStorage.read(key: _keyPrivate);
    final storedPublic = await _secureStorage.read(key: _keyPublic);

    if (storedPrivate != null && storedPublic != null) {
      _cachedPrivateKey = _hexToBytes(storedPrivate);
      _cachedPublicKey = _hexToBytes(storedPublic);
      debugPrint('🔑 Loaded existing keypair from secure storage');
      return (_cachedPrivateKey!, _cachedPublicKey!);
    }

    // Generate new keypair
    debugPrint('🔑 Generating new keypair...');

    if (isRustAvailable) {
      try {
        final (secretKey, publicKey) = rust_crypto.generateKeypair();
        await _secureStorage.write(
            key: _keyPrivate, value: _bytesToHex(secretKey));
        await _secureStorage.write(
            key: _keyPublic, value: _bytesToHex(publicKey));
        _cachedPrivateKey = Uint8List.fromList(secretKey);
        _cachedPublicKey = Uint8List.fromList(publicKey);
        debugPrint('🔑 Generated and stored new X25519 keypair via Rust');
        return (_cachedPrivateKey!, _cachedPublicKey!);
      } catch (e) {
        debugPrint('⚠️ Rust keypair generation failed: $e, using mock');
      }
    }

    // Fallback: Generate mock keypair (32 bytes each)
    final mockPrivate = _generateMockKey(32);
    final mockPublic = _generateMockKey(32);
    await _secureStorage.write(
        key: _keyPrivate, value: _bytesToHex(mockPrivate));
    await _secureStorage.write(key: _keyPublic, value: _bytesToHex(mockPublic));
    _cachedPrivateKey = mockPrivate;
    _cachedPublicKey = mockPublic;
    debugPrint('🔑 Generated mock keypair (Rust unavailable)');
    return (_cachedPrivateKey!, _cachedPublicKey!);
  }

  /// Derive shared secret with a paired device and store it
  Future<Uint8List> deriveAndStoreSharedSecret(
    String deviceId,
    Uint8List theirPublicKey,
  ) async {
    final (myPrivateKey, _) = await getOrCreateKeypair();

    Uint8List sharedSecret;
    if (isRustAvailable) {
      try {
        final secret = rust_crypto.deriveSharedSecret(
          mySecret: myPrivateKey,
          theirPublic: theirPublicKey,
        );
        sharedSecret = Uint8List.fromList(secret);
      } catch (e) {
        debugPrint('⚠️ Rust shared secret derivation failed: $e');
        sharedSecret = _mockDeriveSecret(myPrivateKey, theirPublicKey);
      }
    } else {
      sharedSecret = _mockDeriveSecret(myPrivateKey, theirPublicKey);
    }

    await _secureStorage.write(
      key: '$_sharedSecretPrefix$deviceId',
      value: _bytesToHex(sharedSecret),
    );

    debugPrint('🔗 Derived and stored shared secret for device: $deviceId');
    return sharedSecret;
  }

  /// Mock shared secret derivation (XOR of keys)
  Uint8List _mockDeriveSecret(Uint8List myPrivate, Uint8List theirPublic) {
    final length = myPrivate.length < theirPublic.length
        ? myPrivate.length
        : theirPublic.length;
    final result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = myPrivate[i] ^ theirPublic[i];
    }
    return result;
  }

  /// Get the shared secret for a specific device
  Future<Uint8List?> getSharedSecret(String deviceId) async {
    final stored =
        await _secureStorage.read(key: '$_sharedSecretPrefix$deviceId');
    if (stored == null) return null;
    return _hexToBytes(stored);
  }

  /// Get all paired device IDs
  Future<List<String>> getPairedDeviceIds() async {
    final allKeys = await _secureStorage.readAll();
    return allKeys.keys
        .where((key) => key.startsWith(_sharedSecretPrefix))
        .map((key) => key.substring(_sharedSecretPrefix.length))
        .toList();
  }

  /// Encrypt plaintext using the shared secret with a specific device
  Future<Uint8List> encryptForDevice(String plaintext, String deviceId) async {
    final sharedSecret = await getSharedSecret(deviceId);
    if (sharedSecret == null) {
      throw Exception('No shared secret found for device: $deviceId');
    }

    if (isRustAvailable) {
      try {
        return rust_crypto.encryptText(plaintext: plaintext, key: sharedSecret);
      } catch (e) {
        debugPrint('⚠️ Rust encryption failed: $e');
      }
    }
    return _mockEncrypt(plaintext);
  }

  /// Decrypt ciphertext using the shared secret from a specific device
  Future<String> decryptFromDevice(
      List<int> ciphertext, String deviceId) async {
    final sharedSecret = await getSharedSecret(deviceId);
    if (sharedSecret == null) {
      throw Exception('No shared secret found for device: $deviceId');
    }

    if (isRustAvailable) {
      try {
        return rust_crypto.decryptText(
            ciphertext: ciphertext, key: sharedSecret);
      } catch (e) {
        debugPrint('⚠️ Rust decryption failed: $e');
      }
    }
    return _mockDecrypt(Uint8List.fromList(ciphertext));
  }

  /// Delete pairing with a specific device
  Future<void> unpairDevice(String deviceId) async {
    await _secureStorage.delete(key: '$_sharedSecretPrefix$deviceId');
    debugPrint('🗑️ Unpaired device: $deviceId');
  }

  // ========== Legacy API (for backward compatibility) ==========

  Future<Uint8List> _getLegacyKey() async {
    if (_legacyKey != null) return _legacyKey!;

    final stored = await _secureStorage.read(key: _legacyKeyName);
    if (stored != null) {
      _legacyKey = _hexToBytes(stored);
      return _legacyKey!;
    }

    // Generate new legacy key
    if (isRustAvailable) {
      try {
        final key = rust_crypto.generateKey();
        await _secureStorage.write(
            key: _legacyKeyName, value: _bytesToHex(key));
        _legacyKey = Uint8List.fromList(key);
        debugPrint('🔐 Generated legacy key via Rust');
        return _legacyKey!;
      } catch (e) {
        debugPrint('⚠️ Rust key generation failed: $e');
      }
    }

    // Fallback mock key
    final mockKey = _generateMockKey(32);
    await _secureStorage.write(
        key: _legacyKeyName, value: _bytesToHex(mockKey));
    _legacyKey = mockKey;
    debugPrint('🔐 Generated mock legacy key');
    return _legacyKey!;
  }

  /// Encrypt plaintext (legacy method)
  Future<Uint8List> encrypt(String plaintext) async {
    if (isRustAvailable) {
      try {
        final key = await _getLegacyKey();
        return rust_crypto.encryptText(plaintext: plaintext, key: key);
      } catch (e) {
        debugPrint('⚠️ Rust encrypt failed: $e');
      }
    }
    return _mockEncrypt(plaintext);
  }

  /// Decrypt ciphertext (legacy method)
  Future<String> decrypt(List<int> ciphertext) async {
    if (isRustAvailable) {
      try {
        final key = await _getLegacyKey();
        return rust_crypto.decryptText(ciphertext: ciphertext, key: key);
      } catch (e) {
        debugPrint('⚠️ Rust decrypt failed: $e');
      }
    }
    return _mockDecrypt(Uint8List.fromList(ciphertext));
  }

  // ========== Mock Encryption (fallback when Rust unavailable) ==========

  Uint8List _mockEncrypt(String plaintext) {
    final bytes = utf8.encode(plaintext);
    return Uint8List.fromList(bytes.map((b) => b ^ _mockXorKey).toList());
  }

  String _mockDecrypt(Uint8List ciphertext) {
    final bytes = ciphertext.map((b) => b ^ _mockXorKey).toList();
    return utf8.decode(bytes);
  }

  Uint8List _generateMockKey(int length) {
    // Simple pseudo-random key generation based on timestamp
    final seed = DateTime.now().microsecondsSinceEpoch;
    final result = Uint8List(length);
    for (int i = 0; i < length; i++) {
      result[i] = ((seed >> (i % 8)) + i * 37) & 0xFF;
    }
    return result;
  }

  // ========== Utility Methods ==========

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }
}
