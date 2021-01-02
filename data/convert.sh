#!/bin/sh

# A bit of weirdness -- the input format must be YAML encoded in latin-1;
# if it is UTF-8 you end up with garbage.  (Apparently a bug in json_xs.)
#json_xs -f yaml -t json-utf-8 < questions.yaml > questions.json

# Switched to yaml2json (https://github.com/bronze1man/yaml2json) for
# better UTF-8 support.
if ! command -v yaml2json &> /dev/null; then
  echo
  echo "yaml2json (https://github.com/bronze1man/yaml2json) is required to"
  echo "rebuild the question list."
  echo
  exit
fi

yaml2json < questions.yaml > questions.json
