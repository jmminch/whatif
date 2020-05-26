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

main() async {
  GameServer = new GameServerClass();

  var app = Angel();
  var http = AngelHttp(app);
  var ws = AngelWebSocket(app);

  await app.configure(ws.configureServer);

  app.get('/ws', ws.handleRequest);

  ws.onConnection.listen(socketConnect);

  /* Serve the files from the web/ directory. */
  var fs = const LocalFileSystem();
  var vDir = VirtualDirectory(app, fs, source: fs.directory('./web'));
  app.fallback(vDir.handleRequest);

  /* Return 404 for anything not matched. */
  app.fallback((req, res) => throw AngelHttpException.notFound());

  /* Hardcoded to port 36912 for now. */
  await http.startServer('0.0.0.0', 36912);

  print("Listening on port 36912.");
}

/* Strings coming from the client have the following restrictions:
 * All uppercase (will be converted)
 * Remove any non-ASCII characters and characters that must be
 *   escaped for HTML.
 * No leading/trailing whitespace (will be removed)
 * If there's nothing left, then return an error.
 */
String sanitizeString( str ) {
  if(!(str is String)) return null;

  var s = str.toUpperCase();
  /* Get rid of any characters outside of the 32-127 range. */
  s = s.replaceAll(new RegExp(r"[^\x20-\x7e]"), '');
  /* Get rid of HTML special chars. */
  s = s.replaceAll(new RegExp(r"[\x22\x26\x27\x3c\x3e]"), '');
  s = s.trim();
  if(s.length < 1) return null;
  return s;
}

socketConnect( socket ) async {
  Player p;

  socket.onData.listen((data) {
    var message;

    try {
      message = jsonDecode(data);
    } catch(e) {
      socket.send("error", "message is not JSON data.");
      return;
    }

    if(!(message is Map)) {
      socket.send("error", "message is not JSON map.");
    }

    if(message["event"] == "login") {
      print("handling login event.");

      String name = sanitizeString(message["name"]);
      if(name == null) {
        socket.send("error", "Name is invalid.");
        return;
      }

      String room = sanitizeString(message["room"]);
      if(room == null) {
        socket.send("error", "Room is invalid.");
        return;
      }

      GameServer.addPlayer(name, room);
      p = GameServer.getPlayer(name, room);
      if(p == null) {
        socket.send("error", "Login failed.");
      } else {
        p.connect(socket);
        socket.send("success", "Login successful.");

        /* Tell the player the current state. */
        p.room.notifyState(p);
      }
    } else if(message["event"] is String) {
      p?.handleMessage(message);
    } else {
      socket.send("malformed message.");
    }
  });
}
