/* questions.dart */

import 'dart:io';
import 'dart:convert';
import 'dart:math';

class Question {
  String question = "";
  List<String> answers = <String>[];

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

  List<String> getAnswers( [ int maxAnswers = 6 ] ) {
    /* If the answer list is longer than maxAnswers, remove extra answers
     * randomly.  This maintains the order of the remaining answers. */
    List<String> r = answers.toList();
    while(r.length > maxAnswers) {
      r.removeAt(Random().nextInt(r.length));
    }
    return r;
  }
}

/* The game server keeps a "master" list of all the questions which is
 * never modified, and then the game rooms each have a derived question
 * list structure.  As questions are used in the game room, they are removed
 * from the list until it's empty, at which point the list is refreshed from
 * the master list. */
class QuestionList {
  List<Question> list = <Question>[];
  QuestionList? master;
  bool shuffle = true;
  int length = 0;

  QuestionList( );

  static Future<QuestionList> fromFile( String path ) async {
    var q = QuestionList();
    var parsedList = jsonDecode(await File(path).readAsString());
    parsedList.forEach((e) => q.list.add(Question.fromMap(e)));
    return q;
  }

  QuestionList.fromMaster( QuestionList m,
                           { this.shuffle = true, this.length = 0 } ) {
    master = m;
    list = m.list.toList();
    if(length > 0 && length < list.length) {
      list.removeRange(0, list.length - length);
    }
    if(shuffle) list.shuffle();
  }

  Question nextQuestion( ) {
    if(list.isEmpty) {
      list = master!.list.toList();
      if(length > 0 && length < list.length) {
        list.removeRange(0, list.length - length);
      }
      list.shuffle();
    }

    return list.removeLast();
  }
}
