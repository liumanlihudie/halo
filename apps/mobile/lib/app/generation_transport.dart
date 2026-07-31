// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:halo_mobile/model_runtime/unary_http_transport.dart';

/// HTTP for the generation flow: submit, poll, upload a reference, download a
/// result.
///
/// Separate from [SecureJsonHttpClient] because that one only posts JSON, and
/// this flow needs multipart upload, GET polling and a binary download. Every
/// request still goes through the same [EndpointPolicy], stays https-only, and
/// is capped, so widening the verb set does not widen where bytes may travel.
final class GenerationTransport {
  GenerationTransport({
    required EndpointPolicy endpointPolicy,
    HttpClient Function()? httpClientFactory,
  }) : _endpointPolicy = endpointPolicy,
       _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// A generated image or short video. Beyond this the result is refused
  /// rather than written to a sandbox that has to hold it forever.
  static const maximumDownloadBytes = 64 * 1024 * 1024;
  static const maximumJsonBytes = 2 * 1024 * 1024;
  static const maximumUploadBytes = 10 * 1024 * 1024;

  final EndpointPolicy _endpointPolicy;
  final HttpClient Function() _httpClientFactory;

  Future<Map<String, Object?>> postJson({
    required Uri endpoint,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) => _json(endpoint, 'POST', headers, jsonBody: body);

  Future<Map<String, Object?>> getJson({
    required Uri endpoint,
    required Map<String, String> headers,
  }) => _json(endpoint, 'GET', headers);

  /// Uploads [file] as multipart/form-data and returns the parsed response.
  Future<Map<String, Object?>> uploadImage({
    required Uri endpoint,
    required Map<String, String> headers,
    required File file,
    String purpose = 'generation',
  }) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > maximumUploadBytes) {
      throw const GenerationTransportException('参考图过大或无法读取');
    }
    final boundary =
        '----halo${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final name = file.uri.pathSegments.isEmpty
        ? 'reference'
        : file.uri.pathSegments.last;
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="purpose"\r\n\r\n'
      '$purpose\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="$name"\r\n'
      'Content-Type: ${_mimeFor(name)}\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    return _json(
      endpoint,
      'POST',
      {...headers, 'content-type': 'multipart/form-data; boundary=$boundary'},
      rawBody: <int>[...head, ...bytes, ...tail],
    );
  }

  /// Downloads [url] into [targetDirectory] and returns the written path.
  Future<String> download(
    Uri url,
    Directory targetDirectory,
    String stem,
  ) async {
    await _endpointPolicy.validateBeforeConnect(_requireHttps(url));
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(url);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const GenerationTransportException('结果下载失败');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > maximumDownloadBytes) {
          throw const GenerationTransportException('生成结果超出可保存的大小');
        }
      }
      await targetDirectory.create(recursive: true);
      final extension = _extensionFor(url.path);
      final file = File(
        '${targetDirectory.path}${Platform.pathSeparator}$stem.$extension',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _json(
    Uri endpoint,
    String method,
    Map<String, String> headers, {
    Map<String, Object?>? jsonBody,
    List<int>? rawBody,
  }) async {
    await _endpointPolicy.validateBeforeConnect(_requireHttps(endpoint));
    final client = _httpClientFactory();
    try {
      final request = await client.openUrl(method, endpoint);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (jsonBody != null) {
        request.headers.set('content-type', 'application/json');
        request.add(utf8.encode(jsonEncode(jsonBody)));
      } else if (rawBody != null) {
        request.add(rawBody);
      }
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > maximumJsonBytes) {
          throw const GenerationTransportException('响应过大');
        }
      }
      if (response.statusCode == 429) {
        // The provider asked for a specific wait; ignoring it is how a client
        // gets rate limited harder.
        throw GenerationRateLimited(
          retryAfter: _retryAfter(response.headers.value('retry-after')),
        );
      }
      final decoded = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Upstream error text is never surfaced: it can echo the request,
        // which carries the credential header.
        throw const GenerationTransportException('模型服务返回了错误');
      }
      if (decoded is! Map<String, Object?>) {
        throw const GenerationTransportException('模型服务返回了无法解析的内容');
      }
      return decoded;
    } on GenerationTransportException {
      rethrow;
    } on GenerationRateLimited {
      rethrow;
    } catch (_) {
      throw const GenerationTransportException('无法连接模型服务');
    } finally {
      client.close(force: true);
    }
  }

  static Uri _requireHttps(Uri uri) {
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const GenerationTransportException('只允许 https 地址');
    }
    return uri;
  }

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    if (seconds == null || seconds <= 0 || seconds > 300) return null;
    return Duration(seconds: seconds);
  }

  static String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  static String _extensionFor(String path) {
    final lower = path.toLowerCase();
    for (final candidate in const [
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'mp4',
    ]) {
      if (lower.endsWith('.$candidate')) return candidate;
    }
    // The result URL often carries no extension; the caller knows the kind.
    return lower.contains('video') ? 'mp4' : 'png';
  }
}

final class GenerationTransportException implements Exception {
  const GenerationTransportException(this.safeMessage);

  final String safeMessage;

  @override
  String toString() => 'GenerationTransportException($safeMessage)';
}

final class GenerationRateLimited implements Exception {
  const GenerationRateLimited({this.retryAfter});

  final Duration? retryAfter;
}
