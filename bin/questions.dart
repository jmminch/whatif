/* questions.dart */

import 'dart:io';
import 'dart:convert';

class Question {
  String question;
  String tags;
  List<String> answers = new List<String>();

  Question( );

  Question.fromMap( Map parsedMap ) {
    question = parsedMap["question"];
    parsedMap["answers"].forEach((s) => answers.add(s));
    tags = parsedMap["tags"];
  }

  String targeted( String target ) {
    return question.replaceAll(new RegExp(r"__+"), target);
  }
}

class QuestionList {
  List<Question> list = new List<Question>();
  QuestionList master;
  bool shuffle = false;

  QuestionList.fromFile( String path ) {
    new File(path).readAsString().then((String data) {
      var parsedList = jsonDecode(data);
      parsedList.forEach((e) => list.add(new Question.fromMap(e)));
    });
  }

  QuestionList.fromMaster( this.master ) {
    list = new List<Question>.from(master.list, growable: true);
    list.shuffle();
    shuffle = true;
  }

  Question nextQuestion( ) {
    if(list.length < 1) {
      list = new List<Question>.from(master.list, growable: true);
      list.shuffle();
    }

    return list.removeLast();
  }
}
