// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:rhttp/rhttp.dart';

Future<void> main() async {
  await Rhttp.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  HttpTextResponse? response;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Test Page'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ElevatedButton(
                onPressed: () async {
                  try {
                    final res = await Rhttp.get(
                      'https://example.com',
                      settings: const ClientSettings(
                        tlsSettings: TlsSettings(
                          verifyCertificates: false,
                          trustedRootCertificates: [
                            '''
-----BEGIN CERTIFICATE-----
replace with your certificate
-----END CERTIFICATE-----
''',
                          ],
                        ),
                      ),
                    );
                    setState(() {
                      response = res;
                    });
                  } catch (e, st) {
                    print(e);
                    print(st);
                  }
                },
                child: const Text('Test'),
              ),
              if (response != null) Text(response!.version.toString()),
              if (response != null) Text(response!.statusCode.toString()),
              if (response != null)
                Text(response!.body.substring(0, 100).toString()),
              // if (response != null) Text(response!.headers.toString()),
            ],
          ),
        ),
      ),
    );
  }
}
