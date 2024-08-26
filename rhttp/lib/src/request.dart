import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:rhttp/src/interceptor/interceptor.dart';
import 'package:rhttp/src/model/exception.dart';
import 'package:rhttp/src/model/header.dart';
import 'package:rhttp/src/model/request.dart';
import 'package:rhttp/src/model/response.dart';
import 'package:rhttp/src/model/settings.dart';
import 'package:rhttp/src/rust/api/error.dart' as rust_error;
import 'package:rhttp/src/rust/api/http.dart' as rust;
import 'package:rhttp/src/rust/api/stream.dart' as rust_stream;
import 'package:rhttp/src/util/collection.dart';
import 'package:rhttp/src/util/progress_notifier.dart';
import 'package:rhttp/src/util/stream_listener.dart';

/// Non-Generated helper function that is used by
/// the client and also by the static class.
@internal
Future<HttpResponse> requestInternalGeneric(HttpRequest request) async {
  final interceptors = request.interceptor;

  if (interceptors != null) {
    try {
      final result = await interceptors.beforeRequest(request);
      switch (result) {
        case InterceptorNextResult<HttpRequest>() ||
              InterceptorStopResult<HttpRequest>():
          request = result.value ?? request;
        case InterceptorResolveResult<HttpRequest>():
          return result.response;
      }
    } on RhttpException {
      rethrow;
    } catch (e, st) {
      Error.throwWithStackTrace(RhttpInterceptorException(request, e), st);
    }
  }

  final ProgressNotifier? sendNotifier;
  if (request.onSendProgress != null) {
    switch (request.body) {
      case HttpBodyBytesStream():
        sendNotifier = ProgressNotifier(request.onSendProgress!);
        break;
      case HttpBodyBytes body:
        // transform to Stream
        request = request.copyWith(
          body: HttpBody.stream(
            Stream.fromIterable(body.bytes),
            length: body.bytes.length,
          ),
        );
        sendNotifier = ProgressNotifier(request.onSendProgress!);
        break;
      default:
        sendNotifier = null;
        if (kDebugMode) {
          print(
            'Progress callback is not supported for ${request.body.runtimeType}',
          );
        }
    }
  } else {
    sendNotifier = null;
  }

  HttpHeaders? headers = request.headers;
  headers = _digestHeaders(
    headers: headers,
    body: request.body,
  );

  final rust_stream.Dart2RustStreamReceiver? bodyStream;
  if (request.body is HttpBodyBytesStream) {
    final body = request.body as HttpBodyBytesStream;
    final bodyLength = body.length ?? -1;
    final (sender, receiver) = await rust_stream.createStream();
    listenToStreamWithBackpressure(
        stream: body.stream,
        onData: sendNotifier == null
            ? (data) async {
                await sender.add(data: data);
              }
            : (data) async {
                sendNotifier!.notify(data.length, bodyLength);
                await sender.add(data: data);
              },
        onDone: () async {
          await sender.close();
        });
    bodyStream = receiver;
  } else {
    bodyStream = null;
  }

  final ProgressNotifier? receiveNotifier;
  final bool convertToBytes = request.expectBody == HttpExpectBody.bytes;
  if (request.onReceiveProgress != null) {
    switch (request.expectBody) {
      case HttpExpectBody.stream:
        receiveNotifier = ProgressNotifier(request.onReceiveProgress!);
        break;
      case HttpExpectBody.bytes:
        request = request.copyWith(
          expectBody: HttpExpectBody.stream,
        );
        receiveNotifier = ProgressNotifier(request.onReceiveProgress!);
        break;
      default:
        receiveNotifier = null;
        if (kDebugMode) {
          print(
            'Progress callback is not supported for ${request.expectBody}',
          );
        }
    }
  } else {
    receiveNotifier = null;
  }

  bool exceptionByInterceptor = false;
  try {
    if (request.expectBody == HttpExpectBody.stream) {
      final cancelRefCompleter = Completer<PlatformInt64>();
      final responseCompleter = Completer<rust.HttpResponse>();
      Stream<Uint8List> stream = rust.makeHttpRequestReceiveStream(
        clientAddress: request.client?.ref,
        settings: request.settings?.toRustType(),
        method: request.method._toRustType(),
        url: request.url,
        query: request.query?.entries.map((e) => (e.key, e.value)).toList(),
        headers: headers?._toRustType(),
        body: request.body?._toRustType(),
        bodyStream: bodyStream,
        onResponse: (r) => responseCompleter.complete(r),
        onError: (e) => responseCompleter.completeError(e),
        onCancelToken: (cancelRef) => cancelRefCompleter.complete(cancelRef),
        cancelable: request.cancelToken != null,
      );

      final cancelToken = request.cancelToken;
      if (cancelToken != null) {
        final cancelRef = await cancelRefCompleter.future;
        cancelToken.setRef(cancelRef);
      }

      final rustResponse = await responseCompleter.future;

      if (receiveNotifier != null) {
        final contentLengthStr = rustResponse.headers
                .firstWhereOrNull(
                  (e) => e.$1.toLowerCase() == 'content-length',
                )
                ?.$2 ??
            '-1';
        final contentLength = int.tryParse(contentLengthStr) ?? -1;
        stream = stream.map((event) {
          receiveNotifier!.notify(event.length, contentLength);
          return event;
        });
      }

      HttpResponse response = parseHttpResponse(
        request,
        rustResponse,
        bodyStream: stream,
      );

      if (convertToBytes) {
        final bytes = await stream.toList();
        response = HttpBytesResponse(
          request: request,
          version: response.version,
          statusCode: response.statusCode,
          headers: response.headers,
          body: Uint8List.fromList(bytes.expand((e) => e).toList()),
        );
      }

      if (interceptors != null) {
        try {
          final result = await interceptors.afterResponse(response);
          switch (result) {
            case InterceptorNextResult<HttpResponse>() ||
                  InterceptorStopResult<HttpResponse>():
              response = result.value ?? response;
            case InterceptorResolveResult<HttpResponse>():
              return result.response;
          }
        } on RhttpException {
          exceptionByInterceptor = true;
          rethrow;
        } catch (e, st) {
          exceptionByInterceptor = true;
          Error.throwWithStackTrace(RhttpInterceptorException(request, e), st);
        }
      }

      return response;
    } else {
      final cancelRefCompleter = Completer<PlatformInt64>();
      final responseFuture = rust.makeHttpRequest(
        clientAddress: request.client?.ref,
        settings: request.settings?.toRustType(),
        method: request.method._toRustType(),
        url: request.url,
        query: request.query?.entries.map((e) => (e.key, e.value)).toList(),
        headers: headers?._toRustType(),
        body: request.body?._toRustType(),
        bodyStream: bodyStream,
        expectBody: request.expectBody.toRustType(),
        onCancelToken: (cancelRef) => cancelRefCompleter.complete(cancelRef),
        cancelable: request.cancelToken != null,
      );

      final cancelToken = request.cancelToken;
      if (cancelToken != null) {
        final cancelRef = await cancelRefCompleter.future;
        cancelToken.setRef(cancelRef);
      }

      final rustResponse = await responseFuture;

      HttpResponse response = parseHttpResponse(
        request,
        rustResponse,
      );

      if (interceptors != null) {
        try {
          final result = await interceptors.afterResponse(response);
          switch (result) {
            case InterceptorNextResult<HttpResponse>() ||
                  InterceptorStopResult<HttpResponse>():
              response = result.value ?? response;
            case InterceptorResolveResult<HttpResponse>():
              return result.response;
          }
        } on RhttpException {
          exceptionByInterceptor = true;
          rethrow;
        } catch (e, st) {
          exceptionByInterceptor = true;
          Error.throwWithStackTrace(RhttpInterceptorException(request, e), st);
        }
      }

      return response;
    }
  } catch (e, st) {
    if (exceptionByInterceptor) {
      rethrow;
    }
    if (e is rust_error.RhttpError) {
      RhttpException exception = parseError(request, e);
      if (interceptors == null) {
        // throw converted exception with same stack trace
        Error.throwWithStackTrace(exception, st);
      }

      try {
        final result = await interceptors.onError(exception);
        switch (result) {
          case InterceptorNextResult<RhttpException>() ||
                InterceptorStopResult<RhttpException>():
            exception = result.value ?? exception;
          case InterceptorResolveResult<RhttpException>():
            return result.response;
        }
        Error.throwWithStackTrace(exception, st);
      } on RhttpException {
        rethrow;
      } catch (e, st) {
        Error.throwWithStackTrace(RhttpInterceptorException(request, e), st);
      }
    } else {
      rethrow;
    }
  }
}

HttpHeaders? _digestHeaders({
  required HttpHeaders? headers,
  required HttpBody? body,
}) {
  if (body is HttpBodyJson) {
    headers = _addHeaderIfNotExists(
      headers: headers,
      name: HttpHeaderName.contentType,
      value: 'application/json',
    );
  }

  if (body is HttpBodyBytesStream && body.length != null) {
    headers = _addHeaderIfNotExists(
      headers: headers,
      name: HttpHeaderName.contentLength,
      value: body.length.toString(),
    );
  }

  return headers;
}

HttpHeaders? _addHeaderIfNotExists({
  required HttpHeaders? headers,
  required HttpHeaderName name,
  required String value,
}) {
  if (headers == null || !headers.containsKey(name)) {
    return (headers ?? HttpHeaders.empty).copyWith(
      name: name,
      value: value,
    );
  }
  return headers;
}

extension on HttpMethod {
  rust.HttpMethod _toRustType() {
    return switch (this) {
      HttpMethod.options => rust.HttpMethod.options,
      HttpMethod.get => rust.HttpMethod.get_,
      HttpMethod.post => rust.HttpMethod.post,
      HttpMethod.put => rust.HttpMethod.put,
      HttpMethod.delete => rust.HttpMethod.delete,
      HttpMethod.head => rust.HttpMethod.head,
      HttpMethod.trace => rust.HttpMethod.trace,
      HttpMethod.connect => rust.HttpMethod.connect,
      HttpMethod.patch => rust.HttpMethod.patch,
    };
  }
}

extension on HttpHeaders {
  rust.HttpHeaders _toRustType() {
    return switch (this) {
      HttpHeaderMap map => rust.HttpHeaders.map({
          for (final entry in map.map.entries) entry.key.httpName: entry.value,
        }),
      HttpHeaderRawMap rawMap => rust.HttpHeaders.map(rawMap.map),
      HttpHeaderList list => rust.HttpHeaders.list(list.list),
    };
  }
}

extension on HttpBody {
  rust.HttpBody _toRustType() {
    return switch (this) {
      HttpBodyText text => rust.HttpBody.text(text.text),
      HttpBodyJson json => rust.HttpBody.text(jsonEncode(json.json)),
      HttpBodyBytes bytes => rust.HttpBody.bytes(bytes.bytes),
      HttpBodyBytesStream _ => const rust.HttpBody.bytesStream(),
      HttpBodyForm form => rust.HttpBody.form(form.form),
      HttpBodyMultipart multipart =>
        rust.HttpBody.multipart(rust.MultipartPayload(
          parts: multipart.parts.map((e) {
            final name = e.$1;
            final item = e.$2;
            final rustItem = rust.MultipartItem(
              value: switch (item) {
                MultiPartText() => rust.MultipartValue.text(item.text),
                MultiPartBytes() => rust.MultipartValue.bytes(item.bytes),
                MultiPartFile() => rust.MultipartValue.file(item.file),
              },
              fileName: item.fileName,
              contentType: item.contentType,
            );
            return (name, rustItem);
          }).toList(),
        )),
    };
  }
}
