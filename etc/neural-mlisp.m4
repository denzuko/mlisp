#!/bin/bash
##
# etc/neural-mlisp.m4 — mlisp's neural.sh build template (build-time config)
#
# This is an m4 SOURCE TEMPLATE, not a runtime script. neural.sh's own
# config.m4 is a macro DSL evaluated at `make build` time (m4 expands
# include()/macro calls into a plain shell script with hardcoded
# model/endpoint/method/jpath values — see vendor/neural.sh/src/neural.m4
# for the upstream OpenAI-davinci-003 equivalent of this file).
#
# Built via:
#   m4 -I vendor/neural.sh/src/ etc/neural-mlisp.m4 > bin/neural
# (wired into `make build-all` / `make bin/neural` — see Makefile)
#
# Output: a self-contained shell script requiring only bash, curl, jq, jo
# at runtime — no m4. No NEURAL_ENDPOINT/NEURAL_MODEL env vars are read;
# changing the endpoint/model means editing THIS FILE and rebuilding.
#
# Default target: local Ollama (http://localhost:11434), matching the
# privacy rationale in README.md (bug reports may contain reporter email
# addresses and should stay on-host). To point at OpenAI or another
# OpenAI-compatible endpoint instead, replace the model=/uriendpoint=/
# method=/jpath= block below with config.m4's useOpenAI()/
# useDavinci003() (see vendor/neural.sh/src/neural.m4), or edit
# uriendpoint/model directly.

include(`config.m4')dnl

test -z $1 && exit 1

query=""

case $1 in
    "-"|/dev/stdin)
        read line
        query="${line}"
        ;;
    *)
        query="${*}"
        shift
        ;;
esac

### mlisp default: local Ollama, OpenAI-compatible /v1/completions.
### config.m4's endpoint() macro hardcodes https:// (wrong for a local
### Ollama instance), so uriendpoint is set directly here instead.
model="llama3.2"
uriendpoint="http://localhost:11434/v1/completions"
method="POST"
jpath=".choices[].text"

useJo()

curl -SsLk \
	-X ${method} \
	--data "${data}" \
	-H "Accept: application/json" \
	-H "Content-Type: application/json" \
	"$uriendpoint" | while read line
do
	echo $line | sed 's/data:.//' | sed '/^$/d' | sed '/^\[DONE\]$/d' | jq -r "${jpath}" 2>/dev/null
done | xargs | sed 's/^n n //'
