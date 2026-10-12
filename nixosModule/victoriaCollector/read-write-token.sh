# Sets $token from the write-token credential: exactly one line, optionally
# newline-terminated. Anything else (empty, several lines such as a YAML tokens
# file pasted by mistake) is refused before anything is written, and the message
# never contains the file's content.
token=$(
  cat "$CREDENTIALS_DIRECTORY/write-token"
  echo x
)
token=${token%x} # command substitution would otherwise drop every trailing newline
token=${token%$'\n'}
if [ -z "$token" ]; then
  echo "services.victoriaCollector.writeTokenFile is empty; it must hold exactly one bearer token" >&2
  exit 1
fi
if [[ $token == *$'\n'* ]]; then
  echo "services.victoriaCollector.writeTokenFile must hold exactly one line (the bearer token), but it has several; is it the gateway's YAML tokens file?" >&2
  exit 1
fi
