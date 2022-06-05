YAML := $(shell command -v yaml2json 2> /dev/null)

.PHONY: app questions

app: 
	rm -r app/
	mkdir -p app/bin/
	mkdir -p app/data/
	mkdir -p app/web/
	dart compile exe -o app/bin/server.exe bin/server.dart
	cp data/questions.json app/data/
	cp web/* app/web/

questions:
ifndef YAML
	@echo
	@echo "yaml2json (https://github.com/bronze1man/yaml2json) is required to"
	@echo "rebuild the question list."
	@echo
else
	yaml2json < ./data/questions.yaml > ./data/questions.json
endif
