#!/bin/sh
# Start Postfix
service postfix start

# Start the email processing script
python3 /app/email_to_webhook.py