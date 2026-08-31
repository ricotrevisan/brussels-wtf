#!/bin/sh
set -eu

FORM='https://www.ejustice.just.fgov.be/tsv/tsvf2.htm'
SEARCH='https://www.ejustice.just.fgov.be/cgi_tsv/tsv_rech.pl?language=fr'
ENTERPRISE_NUMBER='0403201185'

form_status="$(curl --silent --show-error --location --output /dev/null --write-out '%{http_code}' "$FORM")"
form_keys="$(curl --silent --show-error --location "$FORM" | awk '
  /name=btw/ { btw=1 }
  /name=numpu/ { numpu=1 }
  END { if (btw && numpu) print "present"; else print "missing" }
')"
printf 'form_status=%s form_keys=%s\n' "$form_status" "$form_keys"

# Discard the response body. The form has no CSRF token or credential.
result="$(curl --silent --show-error --location --output /dev/null \
  --write-out '%{http_code} %{size_download} %{num_redirects} %{url_effective} %{content_type}' \
  --request POST "$SEARCH" \
  --data-urlencode "btw=$ENTERPRISE_NUMBER" \
  --data-urlencode 'naam=' --data-urlencode 'postkode=' \
  --data-urlencode 'localite=' --data-urlencode 'hrc=' \
  --data-urlencode 'pdda=' --data-urlencode 'pddm=' --data-urlencode 'pddj=' \
  --data-urlencode 'pdfa=' --data-urlencode 'pdfm=' --data-urlencode 'pdfj=' \
  --data-urlencode 'numpu=' --data-urlencode 'land=' \
  --data-urlencode 'akte=' --data-urlencode 'jvorm=' \
  --data-urlencode 'language=fr' --data-urlencode 'rech=Recherche')"
set -- $result
printf 'search_status=%s response_bytes_discarded=%s redirects=%s effective_url=%s content_type=%s\n' "$1" "$2" "$3" "$4" "$5"

if [ "$form_status" != 200 ] || [ "$form_keys" != present ] || [ "$1" != 200 ]; then
  printf '%s\n' 'BLOCKED: this complete-form-control search attempt did not return HTTP 200.' >&2
else
  printf '%s\n' 'BLOCKED: HTTP 200 alone does not resolve an exact record or establish permitted access/reuse.' >&2
fi
exit 1
