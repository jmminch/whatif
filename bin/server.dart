/* server.dart */

import 'package:angel_websocket/server.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';
import 'questions.dart';
import 'main.dart';

class GameServerClass {
  Map<String, GameRoom> rooms = new Map<String, GameRoom>();
  QuestionList questionList;

  GameServerClass( ) {
    questionList = new QuestionList.fromFile("./data/questions.json");
  }

  /* Called whenever there is a new socket connection.  Set up a listener
   * for messages. */
  connectSocket( socket ) {
    Player p;

    socket.onData.listen((data) {
      var message;

      if(data.length > 1024) {
        /* No client messages should come anywhere close to this size.  Assume
         * that someone is trying something nasty and close the socket. */
        socket.close();
      }

      /* The expectation is that the message data is a JSON map, and has an
       * event field that categorizes the message; reject any messages that
       * don't match that format. */
      try {
        message = jsonDecode(data);
      } catch(e) {
        socket.send("error", "message is not JSON data.");
        return;
      }

      if(!(message is Map) ||
         !(message["event"] is String)) {
        socket.send("error", "malformed message.");
        return;
      }

      /* The server is responsible for handling login events; the remainder
       * of the events are handled by the player's handleMessage function. */
      if(message["event"] == "login") {
        String name = sanitizeString(message["name"]);
        String room = sanitizeString(message["room"]);
        if(name == null || room == null) {
          socket.send("error", "name or room is invalid.");
          return;
        }
        
        /* Client expects a "success" response to its login as the first
         * message. */
        socket.send("success", "Login successful.");

        /* These calls look up the room and player, and will create the
         * associated objects if required. */
        var r = lookupRoom(room);
        p = r.lookupPlayer(name);

        p.connect(socket);

        log("Login for $name");
      } else {
        /* Defer to player message handler. */
        p?.handleMessage(message);
      }
    });
  }

  /* Look up a room by room code, possibly initializing it if it is not yet. */
  GameRoom lookupRoom( String roomName ) {
    var room = rooms[roomName];

    if(room == null || room.isDefunct()) {
      log("Initializing new room $roomName");
      room = new GameRoom(roomName);
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
  Answer,
  ConfirmResults,  /* allow host to choose when results are shown. */
  Results,
  Final
}

class GameRoom {
  String name;

  Map<String, Player> players = new Map<String, Player>();
  GameState state = GameState.Lobby;
  QuestionList questions;
  Player host;

  List<Player> targets;  /* Shuffled list of players to target for
                            questions. */
  Player currentTarget;
  Question currentQuestion;

  int questionLimit;  /* Maximum questions per game. */
  int roundQuestionLimit;  /* Maximum questions per round. */
  int roundQuestions;  /* number of questions played in the current round. */
  int totalQuestions;  /* number of questions played in the game. */

  DateTime countdownTime;
  DateTime answerTime;
  Timer answerTimer;

  GameRoom( this.name ) {
    questions = new QuestionList.fromMaster(GameServer.questionList);
  }

  /* Look up a player by name, possibly creating a new player object. */
  Player lookupPlayer( String playerName ) {
    if(players[playerName] == null) {
      var p = new Player(playerName);
      p.room = this;

      /* If there is currently no host, then make this player the host. */
      if(host == null) host = p;

      players[playerName] = p;
    }

    return players[playerName];
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
    if(DateTime.now().difference(host.disconnectTime).inMinutes >= 5) 
      return true;
    return false;
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
    host = p;
    changeState(GameState.GameSetup);
  }

  doCompleteResults( Player p ) {
    if(p != host) return;

    /* Depending on the state of the game, can go to round setup,
       back to answer, or to final results. */
    changeState(questionComplete());
  }

  doCompleteFinal( Player p ) {
    if(p != host) return;

    changeState(GameState.Lobby);
  }

  doSelectAnswer( Player p, int answerId ) {
    /* Allow players to submit answers until the results are going to be 
     * revealed. */
    if(state != GameState.Answer &&
       state != GameState.ConfirmResults) return;

    p.answerId = answerId;

    /* If in the answer state, and all active players have responded, then
     * act as if the timer expired early and proceed to the confirm results
     * state. */
    if(state == GameState.Answer) {
      bool checkin = true;
      players.values.forEach( (p) { 
        /* Make sure that all players that are active, or are disconnected
         * but haven't missed a question yet, have responded. */
        if(p.answerId == -1 &&
           (p.state == PlayerState.active ||
            (p.state == PlayerState.disconnected &&
             p.missedQuestions == 0))) {
          checkin = false;
        } 
      });

      if(checkin) answerTimerExpire();
    }
  }

  /* Functions for building and sending "state messages" to the client.
   * Every time the game changes state the client gets sent a message
   * to update what the client is showing to the player. */

  broadcastState( ) => players.values.forEach((p) => notifyState(p));

  notifyState( Player p ) {
    var msg = stateMessage();
    
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
        var remainingTime = countdownTime.difference(new DateTime.now());
        /* Round up duration to nearest second. */
        int seconds = (remainingTime.inMilliseconds + 999) ~/ 1000;
        return { "state" : "countdown",
                 "timeout" : seconds };

      case GameState.Answer:
      case GameState.ConfirmResults:
        return buildAnswerStateMsg();

      case GameState.Results:
        return buildResultsStateMsg();

      case GameState.Final:
        return buildFinalStateMsg();
    }
  }

  Map buildLobbyStateMsg( ) {
    /* lobby message contains:
     *   state = "lobby"
     *   players = [ playerlist ]
     */
    var msgMap = new Map<String, dynamic>();
    msgMap["state"] = "lobby";
    var playerList = players.values.where((p) => 
        (p.state != PlayerState.disconnected)).map((p) => (p.name)).toList();
    msgMap["players"] = playerList;

    return msgMap;
  }

  Map buildAnswerStateMsg( ) {
    /* answer message contains:
     *   state = "answer" OR "confirmresults"
     *   target = string
     *   question = string
     *   answers = list of strings
     *   timeout = int (seconds)
     */

    var msgMap = new Map<String, dynamic>();
    msgMap["state"] = "answer";
    msgMap["target"] = currentTarget.name;
    msgMap["question"] = currentQuestion.targeted(currentTarget.name);
    msgMap["answers"] = currentQuestion.answers;
    var timeout = answerTime.difference(new DateTime.now()).inSeconds;
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

    var msgMap = new Map<String, dynamic>();
    msgMap["state"] = "results";
    msgMap["target"] = currentTarget.name;
    msgMap["question"] = currentQuestion.targeted(currentTarget.name);
    msgMap["answers"] = currentQuestion.answers;

    var resultList = new List<List>();
    /* Report data for players in active or disconnected state, or
     * who provided an answer. */
    var playerList = players.values.where((p) => 
            (p.state == PlayerState.active ||
             (p.state == PlayerState.disconnected && p.missedQuestions < 2) ||
             (p.answerId != -1))).toList();

    playerList.forEach((player) {
      var playerResult = new List();
      playerResult.add(player.name);
      playerResult.add(player.answerId);
      playerResult.add(player.roundScore);
      playerResult.add(player.score);
      resultList.add(playerResult);
    });
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

    var msgMap = new Map<String, dynamic>();
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
        if(newState != GameState.Answer) return false;
        break;

      case GameState.Answer:
        if(newState != GameState.ConfirmResults) return false;
        break;

      case GameState.ConfirmResults:
        if(newState != GameState.Results) return false;
        break;

      case GameState.Results:
        if(newState != GameState.RoundSetup &&
           newState != GameState.Countdown &&
           newState != GameState.Final)
          return false;
        break;

      case GameState.Final:
        if(newState != GameState.Lobby) return false;
        break;
    }

    state = newState;

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
        players.values.forEach((p) {
          if(p.state == PlayerState.pending)
            p.state = PlayerState.active; });

        /* Set scores to 0, etc. */
        players.values.forEach( (p) { 
          p.score = 0; 
          p.questionsAnswered = 0;
        } );
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
        countdownTime = new DateTime.now().add(new Duration(seconds: 3));
        new Timer(new Duration(seconds: 3),
                  () => changeState(GameState.Answer));
        broadcastState();
        break;

      case GameState.Answer:
        answer();
        break;

      case GameState.ConfirmResults:
        broadcastState();
        break;

      case GameState.Results:
        /* Stop answer timer if it's still running. */

        /* Calculate results. */
        scoreQuestion();

        /* Notify all players of results. */
        broadcastState();
        break;

      case GameState.Final:
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
    targets = new List<Player>.from(players.values);
    /* Select active players only. */
    targets = targets.where((p) => (p.state == PlayerState.active)).toList();
    targets.shuffle();

    /* Immediately switch to the countdown. */
    changeState(GameState.Countdown);
  }

  answer( ) {
    /* Let any waiting players into the game. */
    players.values.forEach((p) {
      if(p.state == PlayerState.pending)
        p.state = PlayerState.active; });

    /* Update counters of questions played. */
    roundQuestions++;
    totalQuestions++;

    /* Start timer. */
    var answerTimeout = new Duration(seconds: 31);
    answerTime = new DateTime.now().add(answerTimeout);
    answerTimer = new Timer(answerTimeout, answerTimerExpire);

    /* Pick a target by removing one from the pre-populated targets list. */
    currentTarget = targets.removeLast();

    /* Pick a random question. */
    currentQuestion = questions.nextQuestion();

    /* Set up structures to wait for responses. */
    players.values.forEach( (p) => (p.answerId = -1) );

    /* Notify all players of question and choices. */
    broadcastState();
  }

  /* Called either when the 30-second question timer expires or all
   * active players have checked in. */
  answerTimerExpire( ) {
    /* Need to cancel the timer if this was called early. */
    if(answerTimer != null &&
       answerTimer.isActive) answerTimer.cancel();

    answerTimer = null;
    changeState(GameState.ConfirmResults);
  }

  /* Calculate the scores for one question. */
  scoreQuestion( ) {

    /* Count the number of votes for each answer.  Also zero the roundScore
     * field for each player. */
    List<int> votes = new List<int>.filled(currentQuestion.answers.length, 0);
    players.values.forEach((player) {
      player.roundScore = 0;

      /* Normalize bad values for the answer ID. */
      if(player.answerId == null ||
         player.answerId < 0 ||
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
    });

    /* Now find the maximum number of votes and how many answers had that
     * maximum (in case of ties.) */
    int max = 0;
    int maxCount = 0;

    votes.forEach((v) {
      if(v > max) {
        maxCount = 1;
        max = v;
      } else if(v == max) {
        maxCount++;
      }
    });

    /* Max could be 0 if nobody voted.  Nobody gets points. */
    if(max == 0) return;

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
    players.values.forEach((player) {
      if(max <= 1) {
        /* no points if everyone guesses a different answer. */
      } else {
        if(player.answerId != null &&
           player.answerId >= 0 &&
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
      }

      player.score += player.roundScore;
    });
  }

  GameState questionComplete( ) {
    /* Determine the next state:
     *   - If the round is over, and the maximum number of questions have
     *     been asked, then proceed to Final state.
     *   - If the round is over, and the total number of questions is less
     *     than the max, then proceed to RoundSetup.
     *   - If the round is not over, then proceed to Answer. */
    if(roundQuestions >= roundQuestionLimit ||
       targets.length < 1) {
      if(totalQuestions >= questionLimit) return GameState.Final;
      return GameState.RoundSetup;
    }

    return GameState.Countdown;
  }

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

  disconnectPlayer( Player p ) {
    log("Disconnected player ${p.name}");
    p.state = PlayerState.disconnected;
    if(state == GameState.Lobby) broadcastState();
  }
}

/* Player states:
 * Active
 * Disconnected -- socket is disconnected.  Kept around in case
 *   the player returns.  Will be purged at game start.
 * Pending -- Player logged in, and will be joined to the game at the next
 *  opportunity.
 * Idle -- Player is logged in and connected, but has not answered the
 *   last several answers.  Do not wait for them to answer any questions. */
enum PlayerState {
  active,
  disconnected,
  pending,
  idle
}

class Player {
  String name;
  GameRoom room;
  PlayerState state = PlayerState.pending;
  int score = 0;
  int questionsAnswered = 0;

  WebSocketContext socket;

  int missedPing = 0;
  DateTime disconnectTime; /* Time the player was disconnected. */

  /* Answer ID and score for current round. */
  int answerId = -1;
  int roundScore;

  int missedQuestions = 0;
    /* Number of questions in a row that this player hasn't answered. */

  Player( this.name );

  connect( s ) {
    if(socket != null) {
      socket.send("error", "disconnected");
      socket.close();
    }

    socket = s;

    socket.onClose.listen((_) => disconnect());

    room.connectPlayer(this);

    new Timer(new Duration(seconds: 30), () => ping(s));
    missedPing = 1;
  }

  /* Ping the player every 30 seconds.  This keeps the connection alive, and
   * also lets us detect when the player disconnects.
   * After missing a ping, try once more with a 5-second timeout, and if
   * that fails too then close the socket and disconnect the player. */
  ping(s) {
    if(socket != s) return;

    missedPing++;

    if(missedPing >= 3) {
      /* Missed two pings in succession; disconnect. */
      log("Disconnecting due to missing pings.");
      socket.close();
      disconnect();
      return;
    }

    sendMsg("ping", "ping");

    if(missedPing == 2) {
      new Timer(new Duration(seconds: 5), () => ping(s));
    } else {
      /* missedPing == 1; normal case */
      new Timer(new Duration(seconds: 30), () => ping(s));
    }
  }

  disconnect( ) {
    log("socket disconnected.");
    socket = null;
    disconnectTime = DateTime.now();
    room.disconnectPlayer(this);
  }

  handleMessage( Map msg ) {
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
        room.doSelectAnswer(this, msg["id"]);
        break;

      case "pong":
        missedPing = 0;
        break;
    }
  }

  sendMsg( String event, String data ) => socket?.send(event, data);
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
