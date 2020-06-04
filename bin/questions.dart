/* questions.dart */

import 'dart:io';
import 'dart:convert';

class Question {
  String question;
  List<String> answers = List<String>();

  Question( );

  Question.fromMap( Map parsedMap ) {
    question = parsedMap["question"];
    parsedMap["answers"].forEach((s) => answers.add(s));
  }

  /* Question strings use ___ as a placeholder for the target.  Replace any
   * sequence of multiple underscores with the target's name. */
  String targeted( String target ) {
    return question.replaceAll(RegExp(r"__+"), target);
  }
}

/* The game server keeps a "master" list of all the questions which is
 * never modified, and then the game rooms each have a derived question
 * list structure.  As questions are used in the game room, they are removed
 * from the list until it's empty, at which point the list is refreshed from
 * the master list. */
class QuestionList {
  List<Question> list = List<Question>();
  QuestionList master;
  bool shuffle = false;

  QuestionList( );

  static Future<QuestionList> fromFile( String path ) async {
    var q = QuestionList();
    var parsedList = jsonDecode(await File(path).readAsString());
    parsedList.forEach((e) => q.list.add(Question.fromMap(e)));
    return q;
  }

  QuestionList.fromMaster( this.master ) {
    list = List<Question>.from(master.list, growable: true);
    list.shuffle();
    shuffle = true;
  }

  Question nextQuestion( ) {
    if(list.length < 1) {
      list = List<Question>.from(master.list, growable: true);
      list.shuffle();
    }

    return list.removeLast();
  }
}
