// client.js

var ws;
var login = false;

document.getElementById("login-button").onclick = function (event) {
  // Close existing web socket.
  if(ws) {
    ws.close();
  }

  // Create websocket connection when login is pressed.
  ws = new WebSocket('ws://' + location.hostname +
      (location.port ?  ':' + location.port : '') + '/ws');

  // Wait for websocket connection to send login.
  ws.onopen = function(event) {
    var msg = { event: "login" };
    msg.name = document.getElementById("login-name").value;
    msg.room = document.getElementById("login-room").value;
    ws.send(JSON.stringify(msg));
  };

  ws.addEventListener("message", handleWsMessage);
};

document.getElementById("lobby-start").onclick = function (event) {
  if(!ws) return;
  var msg = { event: "startGame" };
  ws.send(JSON.stringify(msg));
};

document.getElementById("results-cont").onclick = function (event) {
  if(!ws) return;
  var msg = { event: "doCompleteResults" };
  ws.send(JSON.stringify(msg));
};

document.getElementById("final-cont").onclick = function (event) {
  if(!ws) return;
  var msg = { event: "doCompleteFinal" };
  ws.send(JSON.stringify(msg));
};

// Handler for answer buttons.
document.onclick = function(event) {
  if(event.target.className &&
     event.target.className.indexOf('answer-button') != -1) {
    var msg = { event: "answer" };
    if(!ws) return;
    msg.id = parseInt(event.target.id.substring(6));
    ws.send(JSON.stringify(msg));
    changeScreen("afteranswer");
  }
};

function handleWsMessage(event) {
  console.log("Handling event: " + event.data);
  var obj = JSON.parse(event.data);

  if(!login) {
    /* Should be a response to a login request. */
    if(obj.eventName == "success") {
      login = true;
    } else if(obj.eventName == "error") {
      /* Failed login. */
      alert("Login failed.  " + obj.data);
      ws.close();
      ws = null;
      return;
    }
  } else {
    if(obj.eventName == "state") {
      handleStateMessage(JSON.parse(obj.data));
    }
  }
}

function handleStateMessage(msg) {
  switch(msg.state) {
    case "waitstart":
      var playerList = "";
      msg.players.forEach(function(p) {
        playerList += "<span class=\"player-card\">" + p +
                      "</span>";
      });
      document.getElementById("lobby-playerlist").innerHTML = playerList;
      document.getElementById("lobby-myname").innerHTML =
        "Logged in as " + msg.name;
      document.getElementById("lobby-list-head").innerHTML =
        "Room code: " + msg.room;
      changeScreen("lobby");
      break;

    case "answer":
      createAnswerList(msg);
      changeScreen("answer");
      break;

    case "results":
      createResultList(msg);
      changeScreen("results");
      break;

    case "final":
      createFinalResultList(msg);
      changeScreen("final");
      break;
  }
}

function changeScreen(id) {
  document.getElementById("login").style.display =
    (id == "login") ? "block" : "none";
  document.getElementById("lobby").style.display =
    (id == "lobby") ? "block" : "none";
  document.getElementById("answer").style.display =
    (id == "answer") ? "block" : "none";
  document.getElementById("afteranswer").style.display =
    (id == "afteranswer") ? "block" : "none";
  document.getElementById("results").style.display =
    (id == "results") ? "block" : "none";
  document.getElementById("final").style.display =
    (id == "final") ? "block" : "none";
}

function createAnswerList(msg) {
  document.getElementById("answer-question").innerHTML = msg.question;
  document.getElementById("after-answer-question").innerHTML = msg.question;

  var answerList = "";
  for(var i = 0; i < msg.answers.length; i++) {
    answerList +=
      "<button class=\"answer-button\" id=\"answer" + i + "\">" + 
      msg.answers[i] + "</button>";
  }
  document.getElementById("answer-list").innerHTML = answerList;
}

function createResultList(msg) {
  document.getElementById("results-question").innerHTML = msg.question;

  var results = msg.answers.map(x => [ x, 0 ]);
  var noanswer = [ ];

  // First, we're going to figure out who voted for each answer.
  msg.results.forEach(function(r) {
    if(!isNaN(r[1]) &&
       r[1] != null &&
       r[1] >= 0 &&
       r[1] < msg.answers.length) {
      results[r[1]].push(r[0]);
      if(r[2] > 0) results[r[1]][1] = r[2];
    } else {
      noanswer.push(r[0]);
    }
  });

  // Now each element of results is a list with the answer and everyone who
  // voted for it.  Sort results by the length of the elements.
  results.sort((a,b) => b.length - a.length);

  // Now build the output list.
  var resultList = "";

  results.forEach(function(r) {

    resultList += "<div class=\"results-answer\">" +
                  "<div class=\"results-" + (r[1] > 0 ? "winning" : "losing") +
                  "-answer\">" + r.shift() + "</div>" +
                  "<div class=\"results-player-line\">";

    var score = r.shift();
    if(score > 0)
      resultList += "<span class=\"results-score\">+" + score + "</span>";
    r.forEach((s) =>
      resultList += "<span class=\"player-card\">" + s + "</span>");
    resultList += "</div></div>";
  });

  if(noanswer.length > 0) {
    resultList += "<div class=\"results-answer\">" +
                  "<div class=\"results-losing-answer\">" +
                  "No answer</div>" +
                  "<div class=\"results-player-line\">";
    noanswer.forEach((s) =>
      resultList += "<span class=\"player-card\">" + s + "</span>");
    resultList += "</div></div>";
  }

  document.getElementById("results-answerlist").innerHTML = resultList;
}

function createFinalResultList(msg) {
  var resultList = "";
  msg.results.sort((a,b) => b[1] - a[1]);
  msg.results.forEach(function(r) {
    resultList +=
      "<div class=\"final-player-line\"><span class=\"player-name\">" +
      r[0] + "</span><span class=\"player-score\">" + r[1] +
      " pts</span></div>";
  });
  document.getElementById("final-player-list").innerHTML = resultList;
}
