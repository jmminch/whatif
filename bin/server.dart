import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shelf_static/shelf_static.dart';

import 'game.dart';

void main(List<String> args) async {
  var game = await GameServer.load();

  final wsHandler = webSocketHandler((s) => game.connectSocket(s));
  final staticHandler =
          createStaticHandler('./web', defaultDocument: 'index.html');
  final handler = Cascade()
          .add(wsHandler)
          .add(staticHandler)
          .handler;

  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  // Configure a pipeline that logs requests.
  final pipeline = Pipeline().addMiddleware(logRequests()).addHandler(handler);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '36912');
  final server = await serve(pipeline, ip, port);
  print('Server listening on port ${server.port}');
}

log( String s ) {
  print(DateTime.now().toString() + " " + s);
}
