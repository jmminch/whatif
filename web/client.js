// client.js

var ws;
var login = false;
var countdownTimer;
var countdownTime;
var answerTimer;
var curScreen = "login";
var reconnect = false;

document.getElementById("login-button").onclick =
        function (event) { connect(); }

function connect( ) {
  // Close existing web socket.
  if(ws) {
    ws.close();
  }

  // Turn off reconnection until we get a message from the server.
  reconnect = false;

  // Store name and room in local storage.
  localStorage.setItem('name', document.getElementById("login-name").value);
  localStorage.setItem('room', document.getElementById("login-room").value);

  // Create websocket connection when login is pressed.
  ws = new WebSocket(
        (location.protocol === "https:" ? "wss://" : "ws://") +
        location.host + "/ws");

  // Wait for websocket connection to send login.
  ws.onopen = function(event) {
    var msg = { event: "login" };
    msg.name = document.getElementById("login-name").value;
    msg.room = document.getElementById("login-room").value;
    ws.send(JSON.stringify(msg));
  };

  ws.onclose = function(event) {
    ws = null;
 
    if(reconnect) {
      console.log("socket unexpectedly closed; reconnecting.");

      connect();
    } else {
      changeScreen("login");
      alert("Remote disconnected.");
    }
  }

  ws.addEventListener("message", handleWsMessage);
};

// Pressing "enter" on the name field jumps to the room field.
document.getElementById("login-name").onkeyup = function (event) {
  if(event.keyCode === 13) {
    if(document.getElementById("login-name").value.length > 0) {
      event.preventDefault();
      document.getElementById("login-room").focus();
    }
  }
};

// Pressing "enter" on the room field does a login. */
document.getElementById("login-room").onkeyup = function (event) {
  if(event.keyCode === 13) {
    if(document.getElementById("login-name").value.length > 0 &&
       document.getElementById("login-room").value.length > 0) {
      event.preventDefault();
      document.getElementById("login-button").click();
    }
  }
};

document.getElementById("menubutton").onclick = function (event) {
  var displayed = (document.getElementById('menu').style.display == "block");

  if(!displayed) {
    document.getElementById('menu').style.display = "block";
    document.getElementById('menu-overlay').style.visibility = "visible";
    event.target.style.backgroundColor = "#5cdb95";
  } else {
    document.getElementById('menu').style.display = "none";
    document.getElementById('menu-overlay').style.visibility = "hidden";
    event.target.style.backgroundColor = "#379683";
  }
};

document.getElementById("menu-overlay").onclick = function (event) {
  closeMenu();
}

function closeMenu( ) {
  document.getElementById('menu').style.display = "none";
  document.getElementById('menubutton').style.backgroundColor = "#379683";
  document.getElementById('menu-overlay').style.visibility = "hidden";
}

// Handlers for menu buttons
document.getElementById("menu-about").onclick = function (event) {
  closeMenu();
  location.href = "about.html";
};

document.getElementById("menu-endgame").onclick = function (event) {
  closeMenu();
  if(!ws) return;
  var msg = { event: "endGame" };
  ws.send(JSON.stringify(msg));
};

document.getElementById("menu-logout").onclick = function (event) {
  reconnect = false;
  closeMenu();
  if(ws) {
    var msg = { event: "logout" };
    ws.send(JSON.stringify(msg));
    ws.onclose = null;
    ws.close();
  }
  changeScreen("login");
};

// Handlers for the other buttons; just sends appropriate messages
// to the server.
document.getElementById("lobby-start").onclick = function (event) {
  if(!ws) return;
  var msg = { event: "startGame" };
  ws.send(JSON.stringify(msg));
};

document.getElementById("cr-button").onclick = function (event) {
  if(!ws) return;
  var msg = { event: "doConfirmResults" };
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

    /* Disable all answer buttons. */
    var buttons = document.getElementsByClassName("answer-button");
    for(var i = 0; i < buttons.length; i++) buttons[i].disabled = true;

    /* Display the completion text. */
    document.getElementById("answer-complete-text").style.display = "block";

    /* Scroll to the bottom for the "waiting to reveal results" message. */
    window.scrollTo(0, document.body.scrollHeight);
  }
};

/* Handle message from the server. */
function handleWsMessage(event) {
  /* When we get a message from the server, turn on reconnection handling. */
  reconnect = true;

  var obj = JSON.parse(event.data);

  console.log("Handling event: " + event.data);

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
    } else if(obj.eventName == "ping") {
      var msg = { event: "pong" };
      ws.send(JSON.stringify(msg));
    } else if(obj.eventName == "disconnect") {
      // Server explicitly telling us to disconnect; don't reconnect when
      // the socket is closed.
      reconnect = false;
    }
  }
}

/* "state" messages inform the client of changes in the game state; this
 * triggers the client to change what is displayed. */
function handleStateMessage(msg) {
  closeMenu();

  /* Set up the menu bar. */
  document.getElementById("menu-room").innerHTML = "Room: " + msg.room;
  document.getElementById("menu-name").innerHTML = msg.name;
  document.getElementById("menu-room-2").innerHTML = "Room: " + msg.room;
  document.getElementById("menu-host").innerHTML = "Host: " + msg.hostname;

  document.getElementById("menu-endgame").style.display =
    (msg.host && msg.state != "lobby") ? "block" : "none";

  switch(msg.state) {
    case "lobby":
      var playerList = "";
      msg.players.forEach(function(p) {
        playerList += `<span class="player-card">${p}</span>`;
      });
      document.getElementById("lobby-playerlist").innerHTML = playerList;
      document.getElementById("lobby-myname").innerHTML =
        "Logged in as " + msg.name;
      document.getElementById("lobby-list-head").innerHTML =
        "Room code: " + msg.room;

      changeScreen("lobby");
      break;

    case "countdown":
      startCountdown(msg);
      break;

    case "question":
      changeScreen("answer");
      startAnswer(msg);
      break;

    case "confirmresults":
      if(curScreen != "answer") {
        /* This could happen if a player joined while a question was in
         * progress. */
        changeScreen("answer");
        startAnswer(msg);
      }

      if(msg.host) {
        document.getElementById("cr-button").style.display = "block";
        /* Scroll to bottom so the presence of the "reveal results" button
         * is obvious. */
        window.scrollTo(0, document.body.scrollHeight);
      }

      if(answerTimer != null) {
        clearInterval(answerTimer);
        answerTimer = null;
        document.getElementById("header-timer").innerHTML = ":00";
      }
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
  /* Stop countdowns. */
  document.getElementById("countdown").style.visibility = "hidden";
  if(countdownTimer) {
    clearInterval(countdownTimer);
    countdownTimer = null;
  }

  if(answerTimer) {
    clearInterval(answerTimer);
    answerTimer = null;
  }

  /* Set up the header */
  var title = document.getElementById("header-title");
  switch(id) {
    case "login":
    case "lobby":
      title.innerHTML = "WHAT IF?";
      title.style.display = "block";
      break;

    case "final":
      title.innerHTML = "Final Results";
      title.style.display = "block";
      break;

    default:
      title.style.display = "none";
      break;
  }

  document.getElementById("menuline").style.display =
    (id != "login") ? "block" : "none";
  document.getElementById("header-questionbar").style.display =
    (id == "answer" || id == "results") ? "block" : "none";
  document.getElementById("header-timer").style.display =
    (id == "answer") ? "inline-block" : "none";

  document.getElementById("login").style.display =
    (id == "login") ? "block" : "none";
  document.getElementById("lobby").style.display =
    (id == "lobby") ? "block" : "none";
  document.getElementById("answer").style.display =
    (id == "answer") ? "block" : "none";
  document.getElementById("results").style.display =
    (id == "results") ? "block" : "none";
  document.getElementById("final").style.display =
    (id == "final") ? "block" : "none";

  /* Scroll back to top of screen. */
  window.scrollTo(0, 0);

  curScreen = id;
}

function startCountdown(msg) {
  document.getElementById("countdown").style.visibility = "visible";
  countdownTime = msg["timeout"];
  document.getElementById("countdown-timer").innerHTML =
    countdownTime.toString();
  countdownTimer = setInterval(function() {
      countdownTime--;
      if(countdownTime > 0) {
        document.getElementById("countdown-timer").innerHTML =
          countdownTime.toString();
      } else {
        clearInterval(countdownTimer);
        countdownTimer = null;
      }
    }, 1000);
}

function startAnswer(msg) {
  /* Create the header */
  document.getElementById("header-question").innerHTML = msg.question;

  /* Build the list of answer buttons */
  var answerList = "";
  for(var i = 0; i < msg.answers.length; i++) {
    answerList +=
      `<button class="answer-button" id="answer${i}">${msg.answers[i]}</button>`;
  }
  document.getElementById("answer-list").innerHTML = answerList;

  /* Hide the completion text and reveal results button. */
  document.getElementById("answer-complete-text").style.display = "none";
  document.getElementById("cr-button").style.display = "none";

  /* Set up the timer. */
  var t = msg["timeout"];
  document.getElementById("header-timer").innerHTML =
    ":" + (t + 100).toString().substring(1);

  if(answerTimer != null) clearInterval(answerTimer);
  t = msg["timeout"];
  if(t > 0) {
    answerTimer = setInterval(function() {
        t = (t > 0) ? t - 1 : 0;
        document.getElementById("header-timer").innerHTML =
          ":" + (t + 100).toString().substring(1);
        if(t < 1) {
          clearInterval(answerTimer);
          answerTimer = null;
        }
      }, 1000);
  }

  if(msg.pending || msg.answered) {
    /* If the player is pending, then disable answer buttons; they will be
     * allowed in for the next question. */
    var buttons = document.getElementsByClassName("answer-button");
    for(var i = 0; i < buttons.length; i++) buttons[i].disabled = true;

    /* Display the completion text. */
    document.getElementById("answer-complete-text").style.display = "block";

    window.scrollTo(0, document.body.scrollHeight);
  }
}

function createResultList(msg) {
  document.getElementById("header-question").innerHTML = msg.question;

  var results = msg.answers.map(x => [ x, 0 ]);
  var noanswer = [ ];

  // First, we're going to figure out who voted for each answer.
  msg.results.forEach(function(r) {
    if(!isNaN(r[1]) &&
       r[1] != null &&
       r[1] >= 0 &&
       r[1] < msg.answers.length) {
      results[r[1]].push(r[0]);

      /* This is hokey -- if this player was penalized, then stick the HTML
       * for the penalty into the player name, and it will get inserted in
       * the right place. */
      if(r[2] < 0) {
        results[r[1]][results[r[1]].length - 1] +=
          ` <span class="player-penalty">${r[2].toString()}</span>`
      }

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

    resultList += '<div class="results-answer">' +
                  '<div class="results-'+ (r[1] > 0 ? "winning" : "losing") +
                  '-answer">' + r.shift() +
                  '</div><div class="results-player-line">';

    var score = r.shift();
    if(score > 0)
      resultList += `<span class="results-score">+${score}</span>`;
    r.forEach((s) =>
      resultList += `<span class="player-card">${s}</span>`);
    resultList += "</div></div>";
  });

  if(noanswer.length > 0) {
    resultList += '<div class="results-answer">' +
                  '<div class="results-losing-answer">' +
                  'No answer</div>' +
                  '<div class="results-player-line">';
    noanswer.forEach((s) =>
      resultList += `<span class="player-card">${s}</span>`);
    resultList += '</div></div>';
  }

  document.getElementById("results-answerlist").innerHTML = resultList;

  /* The results-cont button will say either "Continue" or "Final Results"
   * depending on the value of msg.final. */
  var b = document.getElementById("results-cont");
  if(msg.host) {
    b.style.visibility = "visible";
    if(msg.finalnext)
      b.innerHTML = "Final Results";
    else
      b.innerHTML = "Continue";
  } else {
    document.getElementById("results-cont").style.visibility = "hidden";
  }
}

function createFinalResultList(msg) {
  var resultList = "";
  msg.results.sort((a,b) => b[1] - a[1]);
  msg.results.forEach(function(r) {
    resultList +=
      '<div class="final-player-line">' +
      `<span class="player-name">${r[0]}</span>` +
      `<span class="player-score">${r[1].toLocaleString()} pts</span></div>`;
  });
  document.getElementById("final-player-list").innerHTML = resultList;

  if(msg.host)
    document.getElementById("final-cont").style.visibility = "visible";
  else 
    document.getElementById("final-cont").style.visibility = "hidden";
}

/* Restore name and room from local storage. */
var storedName = localStorage.getItem('name');
if(storedName) {
  if(document.getElementById("login-name").value.length == 0) {
    document.getElementById("login-name").value = storedName;
  }
}

var storedRoom = localStorage.getItem('room');
if(storedRoom) {
  if(document.getElementById("login-room").value.length == 0) {
    document.getElementById("login-room").value = storedRoom;
  }
}
