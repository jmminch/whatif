/* game.dart */

import 'dart:convert';
import 'dart:async';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'server.dart';
import 'questions.dart';

class GameServer {
  Map<String, GameRoom> rooms = <String, GameRoom>{};
  late QuestionList questionList;

  GameServer();

  static Future<GameServer> load( ) async {
    var s = GameServer();
    s.questionList = await QuestionList.fromFile("./data/questions.json");
    return s;
  }

  static sendMsg( WebSocketChannel socket, String event, String data ) {
    String s = jsonEncode( { 'eventName': event, 'data': data } );
    socket.sink.add(s);
  }

  Future<void> connectSocket( WebSocketChannel socket ) async {

    Player? p;

    await for (String data in socket.stream) {

      dynamic message;

      /* Check to make sure the message is valid. */
      if(data.length > 1024) {
        /* No client messages should come anywhere close to this size.  Assume
         * that someone is trying something nasty and close the socket. */
        break;
      }

      /* The expectation is that the message data is a JSON map, and has an
       * event field that categorizes the message; reject any messages that
       * don't match that format. */
      try {
        message = jsonDecode(data);
      } catch(e) {
        sendMsg(socket, "error", "message is not JSON data.");
        return;
      }

      if(message is! Map || message["event"] is! String) {
        sendMsg(socket, "error", "malformed message.");
        return;
      }

      /* The server is responsible for handling login events; the remainder
       * of the events are handled by the player's handleMessage function. */
      if(message["event"] == "login") {
        String name = sanitizeString(message["name"]);
        String room = sanitizeString(message["room"]);
        int questions = -1;

        /* This is super hackey. If the room code given is of the form
         * <name>:<number>, then we will set an indication to only use the
         * last 'n' questions in the question list. */
        if(room.contains(':')) {
          var m = RegExp(r"^(.+):(\d+)$").firstMatch(room);
          if(m != null) {
            room = m.group(1) as String;
            questions = int.parse(m.group(2) as String);
          }
        }

        if(name == "" || room == "") {
          sendMsg(socket, "error", "name or room is invalid.");
          return;
        }
        
        /* Client expects a "success" response to its login as the first
         * message. */
        sendMsg(socket, "success", "Login successful.");

        /* These calls look up the room and player, and will create the
         * associated objects if required. */
        var r = lookupRoom(room);
        p = r.lookupPlayer(name);

        p.connect(socket);

        log("Login for $name");

        if(questions > 0) {
          /* User gave a question limit; re-initialize the room question
           * list with a new truncated list. */
          if(r.state == GameState.Lobby) {
            r.questions = QuestionList.fromMaster(questionList,
                                                  length: questions);
            log("Initialized list with length $questions");
          }
        }
      } else {
        /* Defer to player message handler. */
        p?.handleMessage(message);
      }

    }

    /* Close the socket. */
    socket.sink.close();

    /* If the socket is connected to a player, disconnect the player. */
    if(p != null && p.socket == socket) {
      p.disconnect();
    }
  }

  /* Look up a room by room code, possibly initializing it if it is not yet. */
  GameRoom lookupRoom( String roomName ) {
    var room = rooms[roomName];

    if(room == null || room.isDefunct()) {
      log("Initializing new room $roomName");
      room = GameRoom(this, roomName);
      rooms[roomName] = room;
    }

    return room;
  }
}

enum GameState {
  Lobby,
  GameSetup,
  RoundSetup,
  Countdown,  /* countdown before next question. */
  Question,
  ConfirmResults,  /* allow host to choose when results are shown. */
  Results,
  Final
}

class GameRoom {
  GameServer game;
  String name;

  Map<String, Player> players = <String, Player>{};
  GameState state = GameState.Lobby;
  late QuestionList questions;
  Player? host;

  List<Player> targets = [];  /* Shuffled list of players to target for
                                 questions. */
  late Player currentTarget;
  late Question currentQuestion;
  List<String> currentAnswers = [];

  int questionLimit = 12;  /* Maximum questions per game. */
  int roundQuestionLimit = 12;  /* Maximum questions per round. */
  int roundQuestions = 0;  /* number of questions played in the current round. */
  int totalQuestions = 0;  /* number of questions played in the game. */

  DateTime countdownTime = DateTime.now();
  DateTime answerTime = DateTime.now();
  Timer? answerTimer;

  Timer? stateTimer;

  GameRoom( this.game, this.name ) {
    if(name.startsWith("_DEBUG")) {
      /* In the debug room, return questions in reverse order without
       * shuffling.  This makes it easy to test newly-added questions. */
      questions = QuestionList.fromMaster(game.questionList,
                                          shuffle: false);
    } else {
      questions = QuestionList.fromMaster(game.questionList);
    }
  }

  /* Look up a player by name, possibly creating a new player object. */
  Player lookupPlayer( String playerName ) {
    if(players[playerName] == null) {
      var p = Player(playerName);
      p.room = this;

      /* If there is currently no host, then make this player the host. */
      host ??= p;

      players[playerName] = p;
    }

    return players[playerName]!;
  }

  /* Determine if a room is defunct.  If it is, then on a new login we'll
   * just re-initialize the room.
   * A room is considered defunct if the host has been disconnected for at
   * least 5 minutes, and all remaining players are disconnected. */
  bool isDefunct( ) {
    if(host == null) return true;
    /* If any players are not disconnected return false */
    if(!players.values.fold(true, (t, p) => (t && p.state ==
          PlayerState.disconnected))) return false;
    /* Return true if the host has been disconnected for more than 5 minutes */
    return (DateTime.now().difference(host!.disconnectTime).inMinutes >= 5);
  }

  /* The following functions are handlers for the various messages that the
   * client may send:
   *  -- start game (pressed start button)
   *  -- select answer (update the chosen answer ID for this player)
   *  -- confirm results (host pressed reveal results button)
   *  -- complete results (host pressed next question/final results button)
   *  -- complete final (host pressed end game button) */

  doStartGame( Player p ) {
    /* Whoever selects "start game" becomes the host. */
    if(state == GameState.Lobby) {
      host = p;
      changeState(GameState.GameSetup);
    }
  }

  doCompleteResults( Player p ) {
    if(p != host) return;

    /* Depending on the state of the game, can go to round setup,
       back to question, or to final results. */
    changeState(questionComplete());
  }

  doCompleteFinal( Player p ) {
    if(p != host) return;

    changeState(GameState.Lobby);
  }

  doSelectAnswer( Player p, int answerId ) {
    /* Allow players to submit answers until the results are going to be 
     * revealed. */
    if(state != GameState.Question &&
       state != GameState.ConfirmResults) return;

    p.answerId = answerId;

    /* If in the question state, and all active players have responded, then
     * act as if the timer expired early and proceed to the confirm results
     * state. */
    if(state == GameState.Question) {
      bool checkin = true;
      for(var p in players.values) {
        /* Make sure that all players that are active, or are disconnected
         * but haven't missed a question yet, have responded. */
        if(p.answerId == -1 &&
           (p.state == PlayerState.active ||
            (p.state == PlayerState.disconnected &&
             p.missedQuestions == 0))) {
          checkin = false;
        } 
      }

      if(checkin) answerTimerExpire();
    }
  }

  doEndGame( Player p ) {
    if(p != host) return;

    log("Ending game for room $name by host request.");

    changeState(GameState.Lobby);
  }

  /* Functions for building and sending "state messages" to the client.
   * Every time the game changes state the client gets sent a message
   * to update what the client is showing to the player. */

  broadcastState( ) => players.values.forEach(notifyState);

  notifyState( Player p ) {
    var msg = stateMessage();

    /* Add common fields */
    if(host != null) {
      msg["hostname"] = host!.name;
    } else {
      msg["hostname"] = "NONE";
    }
    
    /* Also add the player's state. */
    msg["name"] = p.name;
    msg["room"] = name;

    if(p.state == PlayerState.pending) {
      msg["pending"] = true;
    }

    if(p == host) {
      msg["host"] = true;
    }

    if(p.answerId != -1) {
      msg["answered"] = true;
    }

    p.sendMsg("state", jsonEncode(msg));
  }

  Map stateMessage( ) {
    /* Build a game state message describing the current state of this
     * room. */
    switch(state) {
      case GameState.Lobby:
        return buildLobbyStateMsg();

      case GameState.Countdown:
        var remainingTime = countdownTime.difference(DateTime.now());
        /* Round up duration to nearest second. */
        int seconds = (remainingTime.inMilliseconds + 999) ~/ 1000;
        return { "state" : "countdown",
                 "timeout" : seconds };

      case GameState.Question:
      case GameState.ConfirmResults:
        return buildQuestionStateMsg();

      case GameState.Results:
        return buildResultsStateMsg();

      case GameState.Final:
        return buildFinalStateMsg();
      
      default:
        break;
    }

    return { };
  }

  Map buildLobbyStateMsg( ) {
    /* lobby message contains:
     *   state = "lobby"
     *   players = [ playerlist ]
     */
    var msgMap = {};
    msgMap["state"] = "lobby";
    var playerList = players.values.where((p) => 
        (p.state != PlayerState.disconnected)).map((p) => (p.name)).toList();
    msgMap["players"] = playerList;

    return msgMap;
  }

  Map buildQuestionStateMsg( ) {
    /* question message contains:
     *   state = "question" OR "confirmresults"
     *   target = string
     *   question = string
     *   answers = list of strings
     *   timeout = int (seconds)
     */

    var msgMap = {};
    msgMap["state"] = "question";
    msgMap["target"] = currentTarget.name;
    msgMap["question"] = currentQuestion.targeted(currentTarget.name);
    msgMap["answers"] = currentAnswers;
    var timeout = answerTime.difference(DateTime.now()).inSeconds;
    if(timeout < 0) timeout = 0;
    msgMap["timeout"] = timeout;

    if(state == GameState.ConfirmResults) {
      msgMap["state"] = "confirmresults";
      msgMap["timeout"] = 0;
    }

    return msgMap;
  }

  Map buildResultsStateMsg( ) {
    /* results message contains:
     *   state = "results"
     *   target = string
     *   question = string
     *   answers = list of strings
     *   results = [ [ name, choice, round score, total score ] ]
     *   final = bool
     */

    var msgMap = {};
    msgMap["state"] = "results";
    msgMap["target"] = currentTarget.name;
    msgMap["question"] = currentQuestion.targeted(currentTarget.name);
    msgMap["answers"] = currentAnswers;

    var resultList = <List>[];
    /* Report data for players in active or disconnected state, or
     * who provided an answer. */
    var playerList = players.values.where((p) => 
            (p.state == PlayerState.active ||
             (p.state == PlayerState.disconnected && p.missedQuestions < 2) ||
             (p.answerId != -1))).toList();

    for(var player in playerList) {
      var playerResult = [];
      playerResult.add(player.name);
      playerResult.add(player.answerId);
      playerResult.add(player.roundScore);
      playerResult.add(player.score);
      resultList.add(playerResult);
    }
    msgMap["results"] = resultList;

    /* Give an indication if this was the last question (the client will
     * display "Final Results" instead of "Next Question" on the continue
     * button. */
    msgMap["finalnext"] = (questionComplete() == GameState.Final);

    return msgMap;
  }

  Map buildFinalStateMsg( ) {
    /* final message contains:
     *   state = "final"
     *   results = [ [ name, total score ] ]
     */

    var msgMap = {};
    msgMap["state"] = "final";

    /* Report data for players in active state, or who have answered
     * at least one question. */
    var playerList = players.values.where((p) => 
            (p.state == PlayerState.active ||
             p.questionsAnswered != 0));

    msgMap["results"] =
      playerList.map((p) => [ p.name, p.score ]).toList();

    return msgMap;
  }

  /* Functions that handle the transition into a particular state. */
  bool changeState( GameState newState ) {
    /* Make sure transition is valid. */
    switch(state) {
      case GameState.Lobby:
        if(newState != GameState.GameSetup) return false;
        break;

      case GameState.GameSetup:
        if(newState != GameState.RoundSetup) return false;
        break;

      case GameState.RoundSetup:
        if(newState != GameState.Countdown) return false;
        break;

      case GameState.Countdown:
        if(newState != GameState.Question) return false;
        break;

      case GameState.Question:
        if(newState != GameState.ConfirmResults &&
           newState != GameState.Lobby) return false;
        break;

      case GameState.ConfirmResults:
        if(newState != GameState.Results &&
           newState != GameState.Lobby) return false;
        break;

      case GameState.Results:
        if(newState != GameState.RoundSetup &&
           newState != GameState.Countdown &&
           newState != GameState.Final &&
           newState != GameState.Lobby)
          return false;
        break;

      case GameState.Final:
        if(newState != GameState.Lobby) return false;
        break;
    }

    state = newState;

    /* Cancel any ongoing timer. */
    if(stateTimer != null && stateTimer!.isActive) stateTimer!.cancel();
    stateTimer = null;

    /* Transition is OK; do any handling unique to entering each state. */
    switch(newState) {
      case GameState.Lobby:
        broadcastState();
        break;

      case GameState.GameSetup:
        /* Update the player list:
         * - Purge any disconnected players
         * - Allow pending players into the game. */
        players.removeWhere((k, p) => (p.state == PlayerState.disconnected));
        for(var p in players.values) {
          if(p.state == PlayerState.pending)
            p.state = PlayerState.active;
        }

        /* Set scores to 0, etc. */
        for(var p in players.values) {
          p.score = 0; 
          p.questionsAnswered = 0;
        }
        questionLimit = 12;
        roundQuestionLimit = questionLimit;
        totalQuestions = 0;

        changeState(GameState.RoundSetup);
        break;

      case GameState.RoundSetup:
        /* Pick target players, etc. */
        roundSetup();
        break;

      case GameState.Countdown:
        countdownTime = DateTime.now().add(Duration(seconds: 3));
        Timer(Duration(seconds: 3), () => changeState(GameState.Question));
        broadcastState();
        break;

      case GameState.Question:
        startQuestion();
        break;

      case GameState.ConfirmResults:
        stateTimer = Timer(Duration(seconds: 10),
                () {
                  stateTimer = null;
                  if(host == null ||
                     host!.state == PlayerState.disconnected)
                    changeState(GameState.Results);
                });
        broadcastState();
        break;

      case GameState.Results:
        /* Calculate results. */
        scoreQuestion();

        stateTimer = Timer(Duration(seconds: 30),
                () {
                  stateTimer = null;
                  if(host == null ||
                     host!.state == PlayerState.disconnected)
                    doCompleteResults(host!);
                });

        /* Notify all players of results. */
        broadcastState();
        break;

      case GameState.Final:
        stateTimer = Timer(Duration(seconds: 30),
                () {
                  stateTimer = null;
                  if(host == null ||
                     host!.state == PlayerState.disconnected)
                    doCompleteFinal(host!);
                });

        /* Notify all players of final results. */
        broadcastState();
        break;
    }

    return true;
  }

  roundSetup( ) {
    /* Reset the number of questions asked in this round. */
    roundQuestions = 0;

    /* Create a shuffled list of active players to use as the question
     * targets. */
    targets = players.values.toList();
    /* Select active players only. */
    targets = targets.where((p) => (p.state == PlayerState.active)).toList();

    /* Stupid case if there are no active players at all. */
    if(targets.isEmpty) targets = players.values.toList();

    targets.shuffle();

    /* Immediately switch to the countdown. */
    changeState(GameState.Countdown);
  }

  startQuestion( ) {
    /* Let any waiting players into the game. */
    for(var p in players.values) {
      if(p.state == PlayerState.pending)
        p.state = PlayerState.active;
    }

    /* Update counters of questions played. */
    roundQuestions++;
    totalQuestions++;

    /* Start timer. */
    var answerTimeout = Duration(seconds: 31);
    answerTime = DateTime.now().add(answerTimeout);
    answerTimer = Timer(answerTimeout, answerTimerExpire);

    /* Pick a target by removing one from the pre-populated targets list. */
    currentTarget = targets.removeLast();

    /* Pick a random question. */
    currentQuestion = questions.nextQuestion();

    currentAnswers = currentQuestion.getAnswers();

    /* Set up structures to wait for responses. */
    for(var p in players.values) { p.answerId = -1; }

    /* Notify all players of question and choices. */
    broadcastState();
  }

  /* Called either when the 30-second question timer expires or all
   * active players have checked in. */
  answerTimerExpire( ) {
    /* Need to cancel the timer if this was called early. */
    if(answerTimer != null &&
       answerTimer!.isActive) answerTimer!.cancel();

    answerTimer = null;
    changeState(GameState.ConfirmResults);
  }

  /* Calculate the scores for one question. */
  scoreQuestion( ) {

    /* Count the number of votes for each answer.  Also zero the roundScore
     * field for each player. */
    List<int> votes = List<int>.filled(currentAnswers.length, 0);
    for(var player in players.values) {
      player.roundScore = 0;

      /* Normalize bad values for the answer ID. */
      if(player.answerId < 0 ||
         player.answerId >= votes.length) player.answerId = -1;

      if(player.answerId != -1) {
        votes[player.answerId]++;
        player.questionsAnswered++;
        player.missedQuestions = 0;
      } else {
        /* This player did not answer the question.  Increment the
         * missedQuestions count for this player, and possibly switch
         * them to idle state. */
        player.missedQuestions++;
        if(player.state == PlayerState.active &&
            (player.missedQuestions >= 2 ||
             totalQuestions == 1)) {
          player.state = PlayerState.idle;
        }
      }
    }

    /* Now find the maximum number of votes and how many answers had that
     * maximum (in case of ties.) */
    int max = 0;
    int maxCount = 0;

    for(var v in votes) {
      if(v > max) {
        maxCount = 1;
        max = v;
      } else if(v == max) {
        maxCount++;
      }
    }

    /* Max could be 0 if nobody voted.  Nobody gets points.
     * Don't award points if everybody picked a different
     * answer (max = 1). */
    if(max <= 1) return;

    /* Set the score that players that chose a winning answer will get.
     * 1000 for a unique answer; 500 for a 2-way tie; 250 for more ties. */
    int roundScore = 0;

    if(maxCount == 1)
      roundScore = 1000;
    else if (maxCount == 2)
      roundScore = 500;
    else
      roundScore = 250;

    /* Set the round score and update total score for all players. */
    for(var player in players.values) {
      if(player.answerId >= 0 &&
         player.answerId < votes.length &&
         votes[player.answerId] == max) {
        /* Winning answer */
        player.roundScore = roundScore;
      } else {
        /* Losing answer. */
        player.roundScore = 0;

        /* 500 point penalty for choosing wrong if you were the target. */
        if(player == currentTarget) player.roundScore -= 500;
      }

      player.score += player.roundScore;
    }
  }

  GameState questionComplete( ) {
    /* Determine the next state:
     *   - If the round is over, and the maximum number of questions have
     *     been asked, then proceed to Final state.
     *   - If the round is over, and the total number of questions is less
     *     than the max, then proceed to RoundSetup.
     *   - If the round is not over, then proceed to Question. */
    if(roundQuestions >= roundQuestionLimit || targets.isEmpty) {
      if(totalQuestions >= questionLimit) return GameState.Final;
      return GameState.RoundSetup;
    }

    return GameState.Countdown;
  }

  /* Called when a socket is connected for a player.  This could be a new
   * player, or an existing player that is reconnecting. */
  connectPlayer( Player p ) {
    switch(p.state) {
      case PlayerState.pending:
        /* Normal case for a new player.  In the lobby state, then change
         * to active immediately.  Otherwise, state remains pending until
         * starting a new question or returning to the lobby. */
        if(state == GameState.Lobby) p.state = PlayerState.active;
        break;

      default:
        /* Otherwise, the player was disconnected; let them back in
         * immediately. */
        p.state = PlayerState.active;
        break;
    }

    if(state == GameState.Lobby) {
      /* In the lobby, everyone gets notified whenever a player connects. */
      broadcastState();
    } else {
      notifyState(p);
    }
  }

  /* Called when the socket for a player is disconnected. */
  disconnectPlayer( Player p ) {
    log("Disconnected player ${p.name}");
    p.state = PlayerState.disconnected;
    if(state == GameState.Lobby) broadcastState();

    /* If the disconnected player is the host, possibly automatically move
     * to the next state. */
    if(p == host && stateTimer == null) {
      switch(state) {
        case GameState.ConfirmResults:
          changeState(GameState.Results);
          break;
        case GameState.Results:
          doCompleteResults(p);
          break;
        case GameState.Final:
          doCompleteFinal(p);
          break;
        default:
          break;
      }
    }
  }
}

/* Player states:
 * Active
 * Disconnected -- socket is disconnected.  Kept around in case
 *   the player returns.  Will be purged at game start.
 * Pending -- Player logged in, and will be joined to the game at the next
 *  opportunity.
 * Idle -- Player is logged in and connected, but has not answered the
 *   last several questions.  Do not wait for them to answer any questions. */
enum PlayerState {
  active,
  disconnected,
  pending,
  idle
}

class Player {
  String name;
  late GameRoom room;
  PlayerState state = PlayerState.pending;
  int score = 0;
  int questionsAnswered = 0;

  WebSocketChannel? socket;

  int missedPing = 0;
  DateTime disconnectTime = DateTime.now(); /* Time the player was disconnected. */

  /* Answer ID and score for current round. */
  int answerId = -1;
  int roundScore = 0;

  int missedQuestions = 0;
    /* Number of questions in a row that this player hasn't answered. */

  Player( this.name );

  /* Called on socket connection. */
  connect( WebSocketChannel s ) {
    /* Disconnect any existing socket. */
    if(socket != null) {
      /* Tell the client using this socket not to reconnect. */
      sendMsg("disconnect", "disconnect");
      socket!.sink.close();
    }

    socket = s;

    room.connectPlayer(this);

    /* Set up periodic pings. */
    Timer(Duration(seconds: 30), () => ping(s));
    missedPing = 0;
  }

  /* Ping the player every 30 seconds.  This keeps the connection alive, and
   * also lets us detect when the player disconnects.
   * After missing a ping, try once more with a 5-second timeout, and if
   * that fails too then close the socket and disconnect the player. */
  ping( WebSocketChannel s ) {
    if(socket != s) return;

    missedPing++;

    if(missedPing >= 3) {
      /* Missed two pings in succession; disconnect. */
      log("Disconnecting due to missing pings.");
      socket!.sink.close();
      disconnect();
      return;
    }

    sendMsg("ping", "ping");

    if(missedPing == 2) {
      Timer(Duration(seconds: 5), () => ping(s));
    } else {
      /* missedPing == 1; normal case */
      Timer(Duration(seconds: 30), () => ping(s));
    }
  }

  disconnect( ) {
    socket = null;
    disconnectTime = DateTime.now();
    room.disconnectPlayer(this);
  }

  handleMessage( Map msg ) {
    /* Any event besides a "pong" will make the player active. */
    if(msg["event"] != "pong") {
      missedQuestions = 0;
      if(state == PlayerState.idle) state = PlayerState.active;
    }

    switch(msg["event"]) {
      case "startGame":
        room.doStartGame(this);
        break;

      case "doCompleteResults":
        room.doCompleteResults(this);
        break;
      
      case "doCompleteFinal":
        room.doCompleteFinal(this);
        break;

      case "doConfirmResults":
        room.changeState(GameState.Results);
        break;

      case "answer":
        if(msg["id"] is! int) {
          /* Malformed message. */
          break;
        }
        room.doSelectAnswer(this, msg["id"]);
        break;

      case "endGame":
        room.doEndGame(this);
        break;

      case "logout":
        log("Disconnecting due to user request");
        disconnect();
        break;

      case "pong":
        missedPing = 0;
        break;
    }
  }

  sendMsg( String event, String data ) {
    if(socket != null) {
      GameServer.sendMsg(socket!, event, data);
    }
  }
}


/* Strings coming from the client have the following restrictions:
 * All uppercase (will be converted)
 * Remove any non-ASCII characters and characters that must be
 *   escaped for HTML.
 * No leading/trailing whitespace (will be removed)
 * If there's nothing left, then return an error.
 */
String sanitizeString( str ) {
  if(str is! String) return "";

  var s = str.toUpperCase();
  /* Get rid of any characters outside of the 32-127 range. */
  s = s.replaceAll(RegExp(r"[^\x20-\x7e]"), '');
  /* Get rid of HTML special chars. */
  s = s.replaceAll(RegExp(r"[\x22\x26\x27\x3c\x3e]"), '');
  s = s.trim();
  if(s.isEmpty) return "";
  return s;
}
