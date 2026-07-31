import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:halo_mobile/model_runtime/cancellation_token.dart';

enum UnaryTransportErrorCode {
  invalidEndpoint,
  endpointRejected,
  invalidCredential,
  invalidRequest,
  timeout,
  cancelled,
  bodyTooLarge,
  malformedResponse,
  networkFailure,
}

class UnaryTransportException implements Exception {
  const UnaryTransportException(this.code);

  final UnaryTransportErrorCode code;

  @override
  String toString() => 'UnaryTransportException(${code.name})';
}

@immutable
class UnaryHttpTimeouts {
  const UnaryHttpTimeouts({
    this.connect = const Duration(seconds: 10),
    this.response = const Duration(seconds: 30),
    this.total = const Duration(seconds: 60),
  });

  final Duration connect;
  final Duration response;
  final Duration total;

  void validate() {
    if (connect <= Duration.zero ||
        response <= Duration.zero ||
        total <= Duration.zero) {
      throw ArgumentError('Invalid unary HTTP timeout configuration');
    }
  }
}

abstract interface class HostResolver {
  Future<List<InternetAddress>> lookup(String host);
}

class DartIoHostResolver implements HostResolver {
  const DartIoHostResolver();

  @override
  Future<List<InternetAddress>> lookup(String host) =>
      InternetAddress.lookup(host);
}

abstract interface class EndpointPolicy {
  Future<void> validateBeforeConnect(Uri endpoint);

  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress);
}

class PublicEndpointPolicy implements EndpointPolicy {
  const PublicEndpointPolicy({this.resolver = const DartIoHostResolver()});

  final HostResolver resolver;

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {
    try {
      final addresses = await resolver.lookup(endpoint.host);
      if (addresses.isEmpty ||
          addresses.any((address) => !_allows(endpoint, address))) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.endpointRejected,
        );
      }
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {
    if (!_allows(endpoint, remoteAddress)) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  /// Public addresses pass. Behind a fake-IP proxy every name resolves into
  /// 198.18/15, so that range is tolerated too — but only for named hosts:
  /// the proxy re-resolves a name upstream, whereas a literal-IP URL targets
  /// the address itself and stays fully blocked.
  bool _allows(Uri endpoint, InternetAddress address) =>
      !_isNonPublicAddress(address) ||
      (_isBenchmarkFakeIp(address) &&
          InternetAddress.tryParse(endpoint.host) == null);
}

class TrustedProviderEndpointPolicy implements EndpointPolicy {
  TrustedProviderEndpointPolicy({
    required Set<String> providerHosts,
    this.resolver = const DartIoHostResolver(),
  }) : providerHosts = Set.unmodifiable(
         providerHosts.map((host) => host.toLowerCase()),
       ) {
    if (this.providerHosts.isEmpty ||
        this.providerHosts.any(
          (host) =>
              host != host.trim() ||
              Uri.tryParse('https://$host')?.host != host ||
              InternetAddress.tryParse(host) != null,
        )) {
      throw ArgumentError.value(providerHosts, 'providerHosts');
    }
  }

  final Set<String> providerHosts;
  final HostResolver resolver;

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {
    try {
      final addresses = await resolver.lookup(endpoint.host);
      if (addresses.isEmpty ||
          addresses.any((address) => !_allows(endpoint, address))) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.endpointRejected,
        );
      }
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {
    if (!_allows(endpoint, remoteAddress)) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  bool _allows(Uri endpoint, InternetAddress address) =>
      !_isNonPublicAddress(address) ||
      (providerHosts.contains(endpoint.host.toLowerCase()) &&
          _isBenchmarkFakeIp(address));
}

class LocalEndpointPolicy implements EndpointPolicy {
  const LocalEndpointPolicy({this.resolver = const DartIoHostResolver()});

  final HostResolver resolver;

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {
    try {
      final addresses = await resolver.lookup(endpoint.host);
      if (addresses.isEmpty ||
          addresses.any(
            (address) => _addressScope(address) != _AddressScope.loopback,
          )) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.endpointRejected,
        );
      }
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {
    if (_addressScope(remoteAddress) != _AddressScope.loopback) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }
}

class LanEndpointPolicy implements EndpointPolicy {
  const LanEndpointPolicy({
    this.resolver = const DartIoHostResolver(),
    this.allowCredentialHeaders = false,
  });

  final HostResolver resolver;
  final bool allowCredentialHeaders;

  @override
  Future<void> validateBeforeConnect(Uri endpoint) async {
    try {
      final addresses = await resolver.lookup(endpoint.host);
      if (addresses.isEmpty ||
          addresses.any((address) {
            final scope = _addressScope(address);
            return scope != _AddressScope.loopback &&
                scope != _AddressScope.lan;
          })) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.endpointRejected,
        );
      }
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }

  @override
  void validateAfterConnect(Uri endpoint, InternetAddress remoteAddress) {
    final scope = _addressScope(remoteAddress);
    if (scope != _AddressScope.loopback && scope != _AddressScope.lan) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.endpointRejected,
      );
    }
  }
}

enum _AddressScope { public, loopback, lan, nonGlobal }

bool _isNonPublicAddress(InternetAddress address) =>
    _addressScope(address) != _AddressScope.public;

bool _isBenchmarkFakeIp(InternetAddress address) {
  final bytes = address.rawAddress;
  return address.type == InternetAddressType.IPv4 &&
      bytes.length == 4 &&
      bytes[0] == 198 &&
      (bytes[1] == 18 || bytes[1] == 19);
}

_AddressScope _addressScope(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
    return _ipv4Scope(bytes);
  }
  if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
    final allZero = bytes.every((value) => value == 0);
    final loopback =
        bytes.take(15).every((value) => value == 0) && bytes[15] == 1;
    if (loopback) return _AddressScope.loopback;
    if (allZero) return _AddressScope.nonGlobal;

    final isIpv4Compatible = bytes.take(12).every((value) => value == 0);
    if (isIpv4Compatible) {
      final embeddedScope = _ipv4Scope(bytes.sublist(12));
      return switch (embeddedScope) {
        _AddressScope.loopback => _AddressScope.loopback,
        _AddressScope.lan => _AddressScope.lan,
        _ => _AddressScope.nonGlobal,
      };
    }

    final isIpv4Mapped =
        bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    final isIpv4Translated =
        bytes.take(8).every((value) => value == 0) &&
        bytes[8] == 0xff &&
        bytes[9] == 0xff &&
        bytes[10] == 0 &&
        bytes[11] == 0;
    if (isIpv4Mapped || isIpv4Translated) {
      return _AddressScope.nonGlobal;
    }

    final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
    final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
    final siteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0;
    if (uniqueLocal || linkLocal || siteLocal) return _AddressScope.lan;

    final multicast = bytes[0] == 0xff;
    final nat64WellKnown =
        bytes[0] == 0x00 &&
        bytes[1] == 0x64 &&
        bytes[2] == 0xff &&
        bytes[3] == 0x9b &&
        bytes.sublist(4, 12).every((value) => value == 0);
    final nat64Local =
        bytes[0] == 0x00 &&
        bytes[1] == 0x64 &&
        bytes[2] == 0xff &&
        bytes[3] == 0x9b &&
        bytes[4] == 0x00 &&
        bytes[5] == 0x01;
    final discardOnly =
        bytes[0] == 0x01 &&
        bytes[1] == 0x00 &&
        bytes.sublist(2, 8).every((value) => value == 0);
    final ietfSpecial =
        bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] & 0xfe) == 0;
    final documentation =
        bytes[0] == 0x20 &&
        bytes[1] == 0x01 &&
        bytes[2] == 0x0d &&
        bytes[3] == 0xb8;
    final sixToFour = bytes[0] == 0x20 && bytes[1] == 0x02;
    final documentationV2 = bytes[0] == 0x3f && (bytes[1] & 0xf0) == 0xf0;
    final segmentRouting = bytes[0] == 0x5f && bytes[1] == 0x00;
    if (multicast ||
        nat64WellKnown ||
        nat64Local ||
        discardOnly ||
        ietfSpecial ||
        documentation ||
        sixToFour ||
        documentationV2 ||
        segmentRouting) {
      return _AddressScope.nonGlobal;
    }
    return _AddressScope.public;
  }
  return _AddressScope.nonGlobal;
}

_AddressScope _ipv4Scope(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  final third = bytes[2];
  if (first == 127) return _AddressScope.loopback;
  if (first == 10 ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168)) {
    return _AddressScope.lan;
  }
  final nonGlobal =
      first == 0 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 192 && second == 0 && third == 0) ||
      (first == 192 && second == 0 && third == 2) ||
      (first == 192 && second == 88 && third == 99) ||
      (first == 198 && (second == 18 || second == 19)) ||
      (first == 198 && second == 51 && third == 100) ||
      (first == 203 && second == 0 && third == 113) ||
      first >= 224;
  return nonGlobal ? _AddressScope.nonGlobal : _AddressScope.public;
}

String _normalizeUnaryHttpMethod(String method) {
  if (method != 'GET' && method != 'POST') {
    throw ArgumentError('Unsupported unary HTTP method');
  }
  return method;
}

@immutable
class UnaryHttpAdapterRequest {
  UnaryHttpAdapterRequest({
    required String method,
    required this.endpoint,
    required Map<String, String> headers,
    required Set<String> sensitiveHeaderNames,
    required Uint8List bodyBytes,
    required this.timeouts,
    required this.cancellationToken,
    this.endpointPolicy = const PublicEndpointPolicy(),
  }) : method = _normalizeUnaryHttpMethod(method),
       headers = Map.unmodifiable(headers),
       sensitiveHeaderNames = Set.unmodifiable(
         sensitiveHeaderNames.map((name) => name.toLowerCase()),
       ),
       bodyBytes = Uint8List.fromList(bodyBytes);

  final String method;
  final Uri endpoint;
  final Map<String, String> headers;
  final Set<String> sensitiveHeaderNames;
  final Uint8List bodyBytes;
  final UnaryHttpTimeouts timeouts;
  final CancellationToken cancellationToken;
  final EndpointPolicy endpointPolicy;

  @override
  String toString() =>
      'UnaryHttpAdapterRequest(method: $method, origin: ${endpoint.origin}, '
      'path: /***/, sensitiveHeaderCount: ${sensitiveHeaderNames.length})';
}

class RawUnaryHttpResponse {
  RawUnaryHttpResponse({
    required this.statusCode,
    required Map<String, String> headers,
    required this.body,
    required this.remoteAddress,
    Future<void> Function()? close,
  }) : headers = Map.unmodifiable(
         headers.map((key, value) => MapEntry(key.toLowerCase(), value)),
       ),
       _close = close ?? _noOpClose;

  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  final InternetAddress remoteAddress;
  final Future<void> Function() _close;

  Future<void> close() => _close();

  static Future<void> _noOpClose() async {}
}

abstract interface class UnaryHttpAdapter {
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request);
}

typedef HttpClientFactory = HttpClient Function();
typedef SecureSocketConnector =
    Future<SecureSocket> Function(
      Socket socket,
      String host,
      SecurityContext? context,
    );

class DartIoUnaryHttpAdapter implements UnaryHttpAdapter {
  DartIoUnaryHttpAdapter({
    HttpClientFactory? clientFactory,
    this.resolver = const DartIoHostResolver(),
    this.securityContext,
    SecureSocketConnector? secureSocketConnector,
  }) : _clientFactory = clientFactory ?? HttpClient.new,
       _secureSocketConnector = secureSocketConnector ?? _connectSecureSocket;

  final HttpClientFactory _clientFactory;
  final SecureSocketConnector _secureSocketConnector;
  final HostResolver resolver;
  final SecurityContext? securityContext;

  static Future<SecureSocket> _connectSecureSocket(
    Socket socket,
    String host,
    SecurityContext? context,
  ) => SecureSocket.secure(socket, host: host, context: context);

  @override
  Future<RawUnaryHttpResponse> send(UnaryHttpAdapterRequest request) async {
    final method = _normalizeUnaryHttpMethod(request.method);
    _validateUnaryHeaders(request.headers);
    final client = _clientFactory();
    InternetAddress? validatedRemoteAddress;
    void Function()? cancelActiveConnection;
    client
      ..autoUncompress = false
      ..connectionTimeout = request.timeouts.connect;
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      Socket? activeSocket;
      ConnectionTask<Socket>? rawTask;
      var cancelled = false;

      void cancelConnection() {
        cancelled = true;
        rawTask?.cancel();
        activeSocket?.destroy();
      }

      cancelActiveConnection = cancelConnection;
      try {
        final addresses = await resolver.lookup(url.host);
        if (addresses.isEmpty) {
          throw const UnaryTransportException(
            UnaryTransportErrorCode.endpointRejected,
          );
        }
        for (final address in addresses) {
          request.endpointPolicy.validateAfterConnect(url, address);
        }
        final approved = addresses.first;
        if (cancelled) {
          throw const UnaryTransportException(
            UnaryTransportErrorCode.cancelled,
          );
        }
        rawTask = await Socket.startConnect(approved, url.port);
        final socketFuture =
            () async {
              final rawSocket = await rawTask!.socket;
              activeSocket = rawSocket;
              if (cancelled) {
                rawSocket.destroy();
                throw const UnaryTransportException(
                  UnaryTransportErrorCode.cancelled,
                );
              }
              request.endpointPolicy.validateAfterConnect(
                url,
                rawSocket.remoteAddress,
              );
              Socket connectedSocket = rawSocket;
              if (url.scheme == 'https') {
                connectedSocket = await _secureSocketConnector(
                  rawSocket,
                  url.host,
                  securityContext,
                );
                activeSocket = connectedSocket;
                if (cancelled) {
                  connectedSocket.destroy();
                  throw const UnaryTransportException(
                    UnaryTransportErrorCode.cancelled,
                  );
                }
              }
              request.endpointPolicy.validateAfterConnect(
                url,
                connectedSocket.remoteAddress,
              );
              validatedRemoteAddress = connectedSocket.remoteAddress;
              return connectedSocket;
            }().catchError((Object error, StackTrace stackTrace) {
              activeSocket?.destroy();
              if (error is UnaryTransportException) throw error;
              throw const UnaryTransportException(
                UnaryTransportErrorCode.networkFailure,
              );
            });
        return ConnectionTask.fromSocket(socketFuture, cancelConnection);
      } on UnaryTransportException {
        rethrow;
      } catch (_) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.networkFailure,
        );
      }
    };
    HttpClientRequest? ioRequest;
    var closed = false;

    Future<void> closeClient() async {
      if (closed) return;
      closed = true;
      cancelActiveConnection?.call();
      ioRequest?.abort();
      client.close(force: true);
    }

    unawaited(
      request.cancellationToken.whenCancelled.then((_) => closeClient()),
    );
    try {
      if (request.cancellationToken.isCancelled) {
        throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
      }
      final openRace = Completer<HttpClientRequest>();
      final openOperation = client
          .openUrl(method, request.endpoint)
          .timeout(request.timeouts.connect);
      openOperation.then<void>(
        (value) {
          if (openRace.isCompleted) {
            value.abort();
          } else {
            openRace.complete(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!openRace.isCompleted) {
            openRace.completeError(error, stackTrace);
          }
        },
      );
      unawaited(
        request.cancellationToken.whenCancelled.then((_) {
          if (!openRace.isCompleted) {
            openRace.completeError(
              const UnaryTransportException(UnaryTransportErrorCode.cancelled),
            );
          }
        }),
      );
      ioRequest = await openRace.future;
      ioRequest
        ..followRedirects = false
        ..persistentConnection = false;
      request.headers.forEach(ioRequest.headers.set);
      ioRequest.add(request.bodyBytes);
      final response = await ioRequest.close().timeout(
        request.timeouts.response,
        onTimeout: () {
          ioRequest?.abort();
          throw const UnaryTransportException(UnaryTransportErrorCode.timeout);
        },
      );
      final remoteAddress =
          response.connectionInfo?.remoteAddress ?? validatedRemoteAddress;
      if (remoteAddress == null) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.endpointRejected,
        );
      }
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(',');
      });
      return RawUnaryHttpResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: response,
        remoteAddress: remoteAddress,
        close: closeClient,
      );
    } on UnaryTransportException {
      await closeClient();
      rethrow;
    } on TimeoutException {
      await closeClient();
      throw const UnaryTransportException(UnaryTransportErrorCode.timeout);
    } catch (_) {
      await closeClient();
      if (request.cancellationToken.isCancelled) {
        throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
      }
      throw const UnaryTransportException(
        UnaryTransportErrorCode.networkFailure,
      );
    }
  }
}

@immutable
class SecureJsonHttpResponse {
  const SecureJsonHttpResponse({
    required this.statusCode,
    required this.body,
    required this.retryAfter,
  });

  final int statusCode;
  final Map<String, Object?> body;
  final Duration? retryAfter;
}

class SecureJsonHttpClient {
  SecureJsonHttpClient({
    required this.adapter,
    this.endpointPolicy = const PublicEndpointPolicy(),
    this.timeouts = const UnaryHttpTimeouts(),
    this.allowInsecureHttp = false,
  }) {
    timeouts.validate();
  }

  static const maximumBodyBytes = 2 * 1024 * 1024;
  static const maximumJsonDepth = 64;
  static const maximumJsonNodes = 100000;

  final UnaryHttpAdapter adapter;
  final EndpointPolicy endpointPolicy;
  final UnaryHttpTimeouts timeouts;
  final bool allowInsecureHttp;

  Future<SecureJsonHttpResponse> postJson({
    required Uri endpoint,
    required Map<String, Object?> body,
    Map<String, String> headers = const {},
    Set<String> sensitiveHeaderNames = const {},
    CancellationToken? cancellationToken,
  }) => _requestJson(
    method: 'POST',
    endpoint: endpoint,
    body: body,
    headers: headers,
    sensitiveHeaderNames: sensitiveHeaderNames,
    cancellationToken: cancellationToken ?? CancellationToken(),
  );

  Future<SecureJsonHttpResponse> getJson({
    required Uri endpoint,
    required Map<String, String> headers,
    required Set<String> sensitiveHeaderNames,
    required CancellationToken cancellationToken,
  }) => _requestJson(
    method: 'GET',
    endpoint: endpoint,
    headers: headers,
    sensitiveHeaderNames: sensitiveHeaderNames,
    cancellationToken: cancellationToken,
  );

  Future<SecureJsonHttpResponse> _requestJson({
    required String method,
    required Uri endpoint,
    Map<String, Object?>? body,
    required Map<String, String> headers,
    required Set<String> sensitiveHeaderNames,
    required CancellationToken cancellationToken,
  }) async {
    _validateEndpoint(endpoint);
    _validateHeaders(headers);
    if (endpointPolicy is LanEndpointPolicy &&
        !(endpointPolicy as LanEndpointPolicy).allowCredentialHeaders &&
        sensitiveHeaderNames.isNotEmpty) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidCredential,
      );
    }
    final encodedBody = switch (method) {
      'GET' when body == null => Uint8List(0),
      'POST' when body != null => _encodeRequestBody(body),
      _ => throw ArgumentError('Invalid unary JSON request'),
    };
    final callerToken = cancellationToken;
    if (callerToken.isCancelled) {
      throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
    }
    final operationToken = CancellationToken();
    final race = Completer<SecureJsonHttpResponse>();
    var timedOut = false;
    final timer = Timer(timeouts.total, () {
      if (race.isCompleted) return;
      timedOut = true;
      operationToken.cancel();
      race.completeError(
        const UnaryTransportException(UnaryTransportErrorCode.timeout),
      );
    });
    final cancellationSubscription = callerToken.addListener(() {
      if (race.isCompleted) return;
      operationToken.cancel();
      race.completeError(
        const UnaryTransportException(UnaryTransportErrorCode.cancelled),
      );
    });

    final operation = _execute(
      method: method,
      endpoint: endpoint,
      bodyBytes: encodedBody,
      headers: headers,
      sensitiveHeaderNames: sensitiveHeaderNames,
      cancellationToken: operationToken,
    );
    operation.then<void>(
      (value) {
        if (!race.isCompleted) race.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (race.isCompleted) return;
        if (timedOut) {
          race.completeError(
            const UnaryTransportException(UnaryTransportErrorCode.timeout),
          );
        } else if (callerToken.isCancelled) {
          race.completeError(
            const UnaryTransportException(UnaryTransportErrorCode.cancelled),
          );
        } else if (error is UnaryTransportException) {
          race.completeError(error, stackTrace);
        } else {
          race.completeError(
            const UnaryTransportException(
              UnaryTransportErrorCode.networkFailure,
            ),
          );
        }
      },
    );
    try {
      return await race.future;
    } finally {
      timer.cancel();
      cancellationSubscription.dispose();
    }
  }

  Future<SecureJsonHttpResponse> _execute({
    required String method,
    required Uri endpoint,
    required Uint8List bodyBytes,
    required Map<String, String> headers,
    required Set<String> sensitiveHeaderNames,
    required CancellationToken cancellationToken,
  }) async {
    await endpointPolicy.validateBeforeConnect(endpoint);
    if (cancellationToken.isCancelled) {
      throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
    }
    RawUnaryHttpResponse? response;
    try {
      response = await adapter.send(
        UnaryHttpAdapterRequest(
          method: method,
          endpoint: endpoint,
          headers: headers,
          sensitiveHeaderNames: sensitiveHeaderNames,
          bodyBytes: bodyBytes,
          timeouts: timeouts,
          cancellationToken: cancellationToken,
          endpointPolicy: endpointPolicy,
        ),
      );
      endpointPolicy.validateAfterConnect(endpoint, response.remoteAddress);
      final retryAfter = _parseRetryAfter(response.headers['retry-after']);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return SecureJsonHttpResponse(
          statusCode: response.statusCode,
          body: const {},
          retryAfter: retryAfter,
        );
      }
      final rawBody = await _readBounded(
        response.body,
        cancellationToken: cancellationToken,
      );
      final decodedBody = await _decodeContent(
        rawBody,
        response.headers['content-encoding'],
        cancellationToken,
      );
      return SecureJsonHttpResponse(
        statusCode: response.statusCode,
        body: _parseJsonMap(decodedBody),
        retryAfter: retryAfter,
      );
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.networkFailure,
      );
    } finally {
      try {
        await response?.close();
      } catch (_) {
        // Closing is best-effort and must not replace the safe result.
      }
    }
  }

  void _validateEndpoint(Uri endpoint) {
    final validScheme =
        endpoint.scheme == 'https' ||
        (allowInsecureHttp &&
            endpoint.scheme == 'http' &&
            (endpointPolicy is LocalEndpointPolicy ||
                endpointPolicy is LanEndpointPolicy));
    if (!validScheme ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidEndpoint,
      );
    }
  }

  void _validateHeaders(Map<String, String> headers) {
    _validateUnaryHeaders(headers);
  }

  Uint8List _encodeRequestBody(Map<String, Object?> body) {
    try {
      _validateRequestJson(body);
      final builder = BytesBuilder(copy: false);
      final encoder = JsonUtf8Encoder().startChunkedConversion(
        _BoundedByteSink(builder, maximumBodyBytes),
      );
      encoder
        ..add(body)
        ..close();
      return builder.takeBytes();
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidRequest,
      );
    }
  }

  Future<Uint8List> _readBounded(
    Stream<List<int>> stream, {
    required CancellationToken cancellationToken,
  }) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      if (cancellationToken.isCancelled) {
        throw const UnaryTransportException(UnaryTransportErrorCode.cancelled);
      }
      length += chunk.length;
      if (length > maximumBodyBytes) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.bodyTooLarge,
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<Uint8List> _decodeContent(
    Uint8List raw,
    String? encoding,
    CancellationToken cancellationToken,
  ) async {
    final normalized = encoding?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty || normalized == 'identity') {
      return raw;
    }
    if (normalized != 'gzip') {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.malformedResponse,
      );
    }
    try {
      return await _readBounded(
        gzip.decoder.bind(Stream<List<int>>.value(raw)),
        cancellationToken: cancellationToken,
      );
    } on UnaryTransportException {
      rethrow;
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.malformedResponse,
      );
    }
  }

  Map<String, Object?> _parseJsonMap(Uint8List bytes) {
    try {
      final source = utf8.decode(bytes, allowMalformed: false);
      _preflightJson(source);
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException();
      }
      var nodes = 0;
      void validate(Object? value, int depth) {
        nodes++;
        if (nodes > maximumJsonNodes || depth > maximumJsonDepth) {
          throw const FormatException();
        }
        switch (value) {
          case null || bool() || String():
            return;
          case int():
            return;
          case double():
            if (!value.isFinite) throw const FormatException();
          case List<Object?>():
            for (final item in value) {
              validate(item, depth + 1);
            }
          case Map<String, Object?>():
            for (final item in value.values) {
              validate(item, depth + 1);
            }
          default:
            throw const FormatException();
        }
      }

      validate(decoded, 0);
      return Map.unmodifiable(decoded);
    } catch (_) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.malformedResponse,
      );
    }
  }

  void _validateRequestJson(Object? root) {
    final pending = <(Object?, int)>[(root, 0)];
    var nodes = 0;
    while (pending.isNotEmpty) {
      final (value, depth) = pending.removeLast();
      nodes++;
      if (nodes > maximumJsonNodes || depth > maximumJsonDepth) {
        throw const UnaryTransportException(
          UnaryTransportErrorCode.invalidRequest,
        );
      }
      switch (value) {
        case null || bool() || String() || int():
          break;
        case double():
          if (!value.isFinite) {
            throw const UnaryTransportException(
              UnaryTransportErrorCode.invalidRequest,
            );
          }
        case List<Object?>():
          for (final item in value) {
            pending.add((item, depth + 1));
          }
        case Map<String, Object?>():
          for (final entry in value.entries) {
            if (entry.key.isEmpty) {
              throw const UnaryTransportException(
                UnaryTransportErrorCode.invalidRequest,
              );
            }
            pending.add((entry.value, depth + 1));
          }
        default:
          throw const UnaryTransportException(
            UnaryTransportErrorCode.invalidRequest,
          );
      }
    }
  }

  void _preflightJson(String source) {
    var depth = 0;
    var structuralNodes = 1;
    var inString = false;
    var escaped = false;
    for (final codeUnit in source.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (codeUnit == 0x5c) {
          escaped = true;
        } else if (codeUnit == 0x22) {
          inString = false;
        } else if (codeUnit < 0x20) {
          throw const FormatException();
        }
        continue;
      }
      if (codeUnit == 0x22) {
        inString = true;
      } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
        depth++;
        structuralNodes++;
        if (depth > maximumJsonDepth || structuralNodes > maximumJsonNodes) {
          throw const FormatException();
        }
      } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
        depth--;
        if (depth < 0) throw const FormatException();
      } else if (codeUnit == 0x2c) {
        structuralNodes++;
        if (structuralNodes > maximumJsonNodes) {
          throw const FormatException();
        }
      }
    }
    if (depth != 0 || inString || escaped) throw const FormatException();
  }

  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds == null || seconds < 0 || seconds > 86400) return null;
    return Duration(seconds: seconds);
  }
}

void _validateUnaryHeaders(Map<String, String> headers) {
  final headerName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  final unsafeValue = RegExp(r'[\x00-\x1F\x7F]');
  const reserved = {
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
    'te',
    'trailer',
    'upgrade',
    'forwarded',
    'x-http-method-override',
  };
  for (final entry in headers.entries) {
    final normalized = entry.key.toLowerCase();
    if (!headerName.hasMatch(entry.key) ||
        unsafeValue.hasMatch(entry.value) ||
        reserved.contains(normalized) ||
        normalized.startsWith('proxy-') ||
        normalized.startsWith('x-forwarded-')) {
      throw const UnaryTransportException(
        UnaryTransportErrorCode.invalidRequest,
      );
    }
  }
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.builder, this.maximumBytes);

  final BytesBuilder builder;
  final int maximumBytes;
  var _length = 0;

  @override
  void add(List<int> data) {
    _length += data.length;
    if (_length > maximumBytes) {
      throw const UnaryTransportException(UnaryTransportErrorCode.bodyTooLarge);
    }
    builder.add(data);
  }

  @override
  void close() {}
}
