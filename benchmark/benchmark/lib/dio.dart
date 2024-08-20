import 'package:benchmark/dio_adapter.dart';
import 'package:benchmark/dio_transformer.dart';
import 'package:dio/dio.dart';

Future<int> benchmarkDio(String url, int count) async {
  print('benchmark using dio package...');
  final dio = Dio();
  final rhttp = RhttpAdapter();
  await rhttp.init();
  dio.httpClientAdapter = rhttp;
  dio.transformer = FlutterTransformer();

  final stopwatch = Stopwatch()..start();
  final uri = Uri.parse(url);
  for (var i = 0; i < count; i++) {
    final response = await dio.getUri(uri);
    print(response.data.length);
  }

  return stopwatch.elapsedMilliseconds;
}
