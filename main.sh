#!/bin/bash

TELEGRAM_KEY=""
TELEGRAM_CHAT_ID=""
UPDATE_REQUESTS=60
APPROVAL_TEXT="Please approve deployment"
APPROVAL_BUTTON="Approve"
REJECT_BUTTON="Reject"
APPROVED_TEXT="Approved!"
REJECTED_TEXT="Rejected!"
TIMEOUT_TEXT="Timeout!"
ALLOWED_APPROVER_IDS=""

LONGOPTS=TELEGRAM_KEY:,TELEGRAM_CHAT_ID:,UPDATE_REQUESTS:,APPROVAL_TEXT:,APPROVAL_BUTTON:,REJECT_BUTTON:,APPROVED_TEXT:,REJECTED_TEXT:,TIMEOUT_TEXT:,ALLOWED_APPROVER_IDS:

VALID_ARGS=$(getopt --longoptions $LONGOPTS -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1;
fi

while true; do
  if [[ $1 == '' ]]; then break; fi
  echo "$1 => $2"
  case "$1" in
    --TELEGRAM_KEY) TELEGRAM_KEY="$2"; shift 2 ;;
    --TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="$2"; shift 2 ;;
    --UPDATE_REQUESTS) UPDATE_REQUESTS="$2"; shift 2 ;;
    --APPROVAL_TEXT) APPROVAL_TEXT="$2"; shift 2 ;;
    --APPROVAL_BUTTON) APPROVAL_BUTTON="$2"; shift 2 ;;
    --REJECT_BUTTON) REJECT_BUTTON="$2"; shift 2 ;;
    --APPROVED_TEXT) APPROVED_TEXT="$2"; shift 2 ;;
    --REJECTED_TEXT) REJECTED_TEXT="$2"; shift 2 ;;
    --TIMEOUT_TEXT) TIMEOUT_TEXT="$2"; shift 2 ;;
    --ALLOWED_APPROVER_IDS) ALLOWED_APPROVER_IDS="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ -z "$TELEGRAM_KEY" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  echo "❌ TELEGRAM_KEY and TELEGRAM_CHAT_ID are required"
  exit 1
fi

IFS=',' read -ra ALLOWED_APPROVERS <<< "$ALLOWED_APPROVER_IDS"

curl -s "https://api.telegram.org/bot$TELEGRAM_KEY/getUpdates" > /dev/null

generate_random_string() {
  local STRING_LENGTH=12
  local CHAR_SET="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local RANDOM_STRING=""
  for i in $(seq 1 $STRING_LENGTH); do
    local INDEX=$((RANDOM % ${#CHAR_SET}))
    RANDOM_STRING="${RANDOM_STRING}${CHAR_SET:$INDEX:1}"
  done
  echo "$RANDOM_STRING"
}

SESSION_ID=$(generate_random_string)
echo "Session ID: $SESSION_ID"
MESSAGE_ID=""

sendMessage() {
  local SENT=$(curl -s --location --request POST "https://api.telegram.org/bot$TELEGRAM_KEY/sendMessage" \
    --header 'Content-Type: application/json' \
    --data '{
      "chat_id": "'"$TELEGRAM_CHAT_ID"'",
      "text": "'"$APPROVAL_TEXT"'",
      "reply_markup": {
        "inline_keyboard": [
          [
            {"text": "'"$APPROVAL_BUTTON"'", "callback_data": "a:'"$SESSION_ID"'"},
            {"text": "'"$REJECT_BUTTON"'", "callback_data": "r:'"$SESSION_ID"'"}
          ]
        ]
      }
    }')

  MESSAGE_ID=$(echo "$SENT" | awk -F '"message_id":' '{print $2}' | awk -F ',' '{print $1}')
  echo "Message ID: $MESSAGE_ID"
}

getUpdates() {
  local UPDATES=$(curl -s --location --request POST "https://api.telegram.org/bot$TELEGRAM_KEY/getUpdates" \
    --header 'Content-Type: application/json' \
    --data '{
      "offset": -1,
      "timeout": 0,
      "allowed_updates": ["callback_query"]
    }')

  echo "📨 RAW UPDATES:" >&2
  echo "$UPDATES" >&2

  local CALLBACK_DATA=$(echo "$UPDATES" | grep -o "\"data\":\"[ar]:$SESSION_ID\"" | head -n1 | cut -d':' -f2 | tr -d '" ')
  local CALLBACK_TYPE=${CALLBACK_DATA:0:1}
  local FROM_ID=$(echo "$UPDATES" | grep -o '"from":{"id":[0-9]*' | head -n1 | grep -o '[0-9]*$')
  local CALLBACK_ID=$(echo "$UPDATES" | grep -o '"id":"[^"]*"' | head -n1 | cut -d':' -f2 | tr -d '"')

  echo "🔎 FROM_ID = $FROM_ID, CALLBACK_TYPE = $CALLBACK_TYPE, SESSION_ID = $SESSION_ID" >&2

  if [ -z "$CALLBACK_TYPE" ] || [ -z "$FROM_ID" ]; then
    echo 0
    return
  fi

  for ALLOWED_ID in "${ALLOWED_APPROVERS[@]}"; do
    if [[ "$FROM_ID" == "$ALLOWED_ID" ]]; then
      if [[ "$CALLBACK_TYPE" == "a" ]]; then
        echo 1
        return
      elif [[ "$CALLBACK_TYPE" == "r" ]]; then
        echo 2
        return
      fi
    fi
  done

  echo "⛔ Unauthorized user attempted approval: $FROM_ID" >&2

  curl -s --location --request POST "https://api.telegram.org/bot$TELEGRAM_KEY/answerCallbackQuery" \
    --header 'Content-Type: application/json' \
    --data '{
      "callback_query_id": "'"$CALLBACK_ID"'",
      "text": "⛔ You are not allowed to approve this.",
      "show_alert": true
    }' > /dev/null

  echo 0
}


updateMessage() {
  local text="$1"
  curl -s --location --request POST "https://api.telegram.org/bot$TELEGRAM_KEY/editMessageText" \
    --header 'Content-Type: application/json' \
    --data '{
      "chat_id": "'"$TELEGRAM_CHAT_ID"'",
      "message_id": "'"$MESSAGE_ID"'",
      "text": "'"$text"'"
    }'
}

# Run logic
sendMessage

UPDATE_REQUESTS_COUNTER=0
while true; do
  RESULT=$(getUpdates)
  echo "Result: $RESULT"

  if [ "$RESULT" -eq 1 ]; then
    echo "✅ Approved"
    updateMessage "$APPROVED_TEXT"
    exit 0
  elif [ "$RESULT" -eq 2 ]; then
    echo "❌ Rejected"
    updateMessage "$REJECTED_TEXT"
    exit 1
  fi

  if [ "$UPDATE_REQUESTS_COUNTER" -gt "$UPDATE_REQUESTS" ]; then
    echo "⏳ Timeout reached"
    updateMessage "$TIMEOUT_TEXT"
    exit 1
  fi

  UPDATE_REQUESTS_COUNTER=$((UPDATE_REQUESTS_COUNTER + 1))
  echo "Waiting for approve or reject $UPDATE_REQUESTS_COUNTER/$UPDATE_REQUESTS"
  sleep 1
done
