/* main.dart */

import 'package:angel_framework/angel_framework.dart';
import 'package:angel_framework/http.dart';
import 'package:angel_static/angel_static.dart';
import 'package:angel_websocket/server.dart';
import 'package:file/local.dart';
import 'dart:convert';
import 'dart:async';

import 'server.dart';

GameServerClass GameServer;

int port = 36912;
String interface = "127.0.0.1";

main() async {
  GameServer = new GameServerClass();

  var app = Angel();
  var http = AngelHttp(app);
  var ws = AngelWebSocket(app);

  await app.configure(ws.configureServer);

  app.get('/ws', ws.handleRequest);

  ws.onConnection.listen((s) => GameServer.connectSocket(s));

  /* Serve the files from the web/ directory. */
  var fs = const LocalFileSystem();
  var vDir = VirtualDirectory(app, fs, source: fs.directory('./web'));
  app.fallback(vDir.handleRequest);

  /* Return 404 for anything not matched. */
  app.fallback((req, res) => throw AngelHttpException.notFound());

  /* Hardcoded to port 36912 for now. */
  await http.startServer(interface, port);

  log("Listening on $interface port $port.");
}

log( String s ) {
  print(new DateTime.now().toString() + " " + s);
}
