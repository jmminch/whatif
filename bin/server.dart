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

  Player addPlayer( String name, String room ) {
    /* Find out if the room already exists. */
    if(rooms[room] == null) {
      /* TODO: if the room is defunct, reinitialize it. */
      rooms[room] = new GameRoom(room);
    }

    var gr = rooms[room];

    /* Check whether this player already exists in this room. */
    if(gr.players[name] == null) {
      var p = new Player(name);
      gr.addPlayer(p);
    }

    return gr.players[name];
  }

  getPlayer( String name, String room ) => rooms[room]?.players[name];
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
  Timer countdownTimer;
  DateTime answerTime;
  Timer answerTimer;

  GameRoom( this.name ) {
    questions = new QuestionList.fromMaster(GameServer.questionList);
  }

  addPlayer( Player p ) {
    players[p.name] = p;
    p.room = this;

    /* If there is currently no host, then make this player the host. */
    if(host == null) host = p;

    if(state == GameState.Lobby) broadcastState();
  }

  removePlayer( Player p ) {
    players.remove(p.name);
  }

  Player getPlayer( String name ) => players[name];

  doStartGame( Player p ) {
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

  /* TODO: need an end game option. */

  doSelectAnswer( Player p, int answerId ) {
    /* Allow players to submit answers until the results are going to be 
     * revealed. */
    if(state != GameState.Answer &&
       state != GameState.ConfirmResults) return;

    p.answerId = answerId;

    /* If in the answer state, and all active players have responded, then
     * move immediately to the ConfirmResults state. */
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

  countdownComplete( ) {
    countdownTimer = null;
    changeState(GameState.Answer);
  }

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

    GameState oldState = state;
    state = newState;

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
        players.values.forEach( (p) { p.score = 0; } );
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
        if(countdownTimer != null) {
          countdownTimer.cancel();
        }
        countdownTimer = new Timer(new Duration(seconds: 3),
                                   countdownComplete);
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

  notifyAll( String event, String data ) {
    players.values.forEach((player) => player.sendMsg(event, data));
  }

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
     *   host = true/false  -- TODO
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
             (p.answerId >= 0 &&
              p.answerId < currentQuestion.answers.length))).toList();

    playerList.forEach((player) {
      var playerResult = new List();
      playerResult.add(player.name);
      var answer = player.answerId;
      if(answer == null ||
         answer < 0 ||
         answer >= currentQuestion.answers.length) answer = -1;
      playerResult.add(answer);
      playerResult.add(player.roundScore);
      playerResult.add(player.score);
      resultList.add(playerResult);
    });
    msgMap["results"] = resultList;

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

    var resultList = new List<List>();

    /* Report data for players in active or disconnected state, or
     * who have a nonzero score. */
    var playerList = players.values.where((p) => 
            (p.state == PlayerState.active ||
             p.state == PlayerState.disconnected ||
             p.score != 0)).toList();

    playerList.forEach((player) {
      var playerResult = new List();
      playerResult.add(player.name);
      playerResult.add(player.score);
      resultList.add(playerResult);
    });
    msgMap["results"] = resultList;

    return msgMap;
  }

  /* Functions that handle the transition into a particular state. */
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
      if(player.answerId != null &&
         player.answerId >= 0 &&
         player.answerId < votes.length) {
        votes[player.answerId]++;
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

    notifyState(p);
  }

  disconnectPlayer( Player p ) {
    print("Disconnected player ${p.name}");
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

  WebSocketContext socket;
  Timer pingTimer;
  int missedPing = 0;

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
      print("Disconnecting due to missing pings.");
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
    print("socket disconnected.");
    socket = null;
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

dynamic randomChoice( List l ) {
  return l[new Random().nextInt(l.length)];
}
