#!/bin/sh
# etc/unsubscribe-cgi/unsub.sh — RFC 8058 one-click unsubscribe CGI
#
# Deploy as a CGI script on your web server.  Configure your list with:
#   mlisp-admin set-option <list-id> unsubscribe-url https://lists.example.com/unsub/<list-id>
#
# Then install this script so that URL maps to it, e.g. in Apache:
#   ScriptAlias /unsub/ /usr/local/lib/mlisp/unsub.sh
#   Alias /unsub /usr/local/lib/mlisp/unsub.sh
#
# RFC 8058 requires:
#   - Accept GET (show unsubscribe confirmation page)
#   - Accept POST with body "List-Unsubscribe=One-Click" (process unsubscribe)
#
# Configuration:
MLISP_ADMIN="${MLISP_ADMIN:-/usr/local/bin/mlisp-admin}"
MLISP_HOME="${MLISP_HOME:-/var/lib/mlisp}"
# The list-id is passed as PATH_INFO or QUERY_STRING list= parameter

# Extract list-id from PATH_INFO (/unsub/mlisp-discuss) or QUERY_STRING (list=mlisp-discuss)
LIST_ID=""
if [ -n "$PATH_INFO" ]; then
    LIST_ID=$(echo "$PATH_INFO" | sed 's|^/||' | cut -d/ -f1)
fi
if [ -z "$LIST_ID" ] && echo "$QUERY_STRING" | grep -q "list="; then
    LIST_ID=$(echo "$QUERY_STRING" | sed 's/.*list=\([^&]*\).*/\1/')
fi

# Extract subscriber address from query string or POST body
SUBSCRIBER=""
if echo "$QUERY_STRING" | grep -q "email="; then
    SUBSCRIBER=$(echo "$QUERY_STRING" | sed 's/.*email=\([^&]*\).*/\1/' | \
                 sed 's/%40/@/g' | sed 's/+/ /g')
fi

case "$REQUEST_METHOD" in
    GET)
        # Show confirmation page
        printf 'Content-Type: text/html\r\n\r\n'
        cat << HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Unsubscribe from ${LIST_ID}</title></head>
<body>
<h1>Unsubscribe from ${LIST_ID}</h1>
<form method="POST" action="${REQUEST_URI}">
<input type="hidden" name="List-Unsubscribe" value="One-Click">
<p>Click below to unsubscribe <strong>${SUBSCRIBER}</strong> from <strong>${LIST_ID}</strong>.</p>
<button type="submit">Unsubscribe</button>
</form>
</body></html>
HTML
        ;;

    POST)
        # Read POST body and check for RFC 8058 token
        read -r BODY

        if echo "$BODY" | grep -q "List-Unsubscribe=One-Click"; then
            if [ -n "$LIST_ID" ] && [ -n "$SUBSCRIBER" ]; then
                # Process unsubscribe
                "$MLISP_ADMIN" --home "$MLISP_HOME" rm-sub "$LIST_ID" "$SUBSCRIBER" 2>/dev/null
                STATUS=$?
                printf 'Content-Type: text/plain\r\n\r\n'
                if [ $STATUS -eq 0 ]; then
                    printf 'Unsubscribed %s from %s.\n' "$SUBSCRIBER" "$LIST_ID"
                else
                    printf 'Error: could not unsubscribe (address may not be subscribed).\n'
                fi
            else
                printf 'Content-Type: text/plain\r\nStatus: 400 Bad Request\r\n\r\n'
                printf 'Missing list-id or subscriber address.\n'
            fi
        else
            printf 'Content-Type: text/plain\r\nStatus: 400 Bad Request\r\n\r\n'
            printf 'Invalid request (missing List-Unsubscribe=One-Click).\n'
        fi
        ;;

    *)
        printf 'Content-Type: text/plain\r\nStatus: 405 Method Not Allowed\r\n\r\n'
        printf 'Method not allowed.\n'
        ;;
esac
