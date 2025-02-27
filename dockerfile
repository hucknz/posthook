FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies first
RUN apt-get update && \
    echo "postfix postfix/mailname string mail.example.com" | debconf-set-selections && \
    echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    wget \
    python3 \
    python3-pip \
    supervisor \
    postfix \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install webhook handler dependencies
RUN pip3 install --no-cache-dir requests

# Create directory for email script
RUN mkdir -p /opt/scripts

# Create python script to handle emails and forward to webhook
COPY <<'EOT' /opt/scripts/email_to_webhook.py
#!/usr/bin/env python3
import sys
import email
import requests
import json
import os
from email.parser import Parser
from base64 import b64encode
import configparser

# Load configuration from file
config = configparser.ConfigParser()
config.read('/etc/postfix/webhook_config.ini')

# Get webhook URL from configuration
WEBHOOK_URL = config.get('webhook', 'url', fallback='http://localhost:8080/webhook')

# Read email from stdin (piped from Postfix)
message_data = sys.stdin.read()

# Parse the email
message = email.message_from_string(message_data)

# Extract email components
email_data = {
    'from': message.get('From', ''),
    'to': message.get('To', ''),
    'subject': message.get('Subject', ''),
    'date': message.get('Date', ''),
    'headers': dict(message.items()),
    'body': {}
}

# Process message body parts
for part in message.walk():
    content_type = part.get_content_type()
    content_disposition = part.get('Content-Disposition', '')
    
    # Skip multipart containers
    if part.is_multipart():
        continue
        
    # Get the payload
    payload = part.get_payload(decode=True)
    if payload:
        # Handle text content
        if content_type.startswith('text/'):
            charset = part.get_content_charset() or 'utf-8'
            try:
                decoded_payload = payload.decode(charset)
                email_data['body'][content_type] = decoded_payload
            except:
                # If decoding fails, use base64
                email_data['body'][content_type] = b64encode(payload).decode('ascii')
        # Handle attachments or other binary content
        elif 'attachment' in content_disposition or 'inline' in content_disposition:
            filename = part.get_filename() or 'unknown'
            if 'attachments' not in email_data:
                email_data['attachments'] = []
            email_data['attachments'].append({
                'filename': filename,
                'content_type': content_type,
                'data': b64encode(payload).decode('ascii')
            })
        # Other content types
        else:
            if 'other' not in email_data:
                email_data['other'] = []
            email_data['other'].append({
                'content_type': content_type,
                'data': b64encode(payload).decode('ascii')
            })

# Send to webhook
try:
    response = requests.post(
        WEBHOOK_URL,
        json=email_data,
        headers={'Content-Type': 'application/json'}
    )
    print(f"Email sent to webhook. Status code: {response.status_code}")
    sys.exit(0)
except Exception as e:
    print(f"Error sending to webhook: {str(e)}")
    sys.exit(1)
EOT

# Make sure the script is executable
RUN chmod +x /opt/scripts/email_to_webhook.py

# Add a webhook user
RUN useradd -r -s /bin/false webhook

# Make sure the scripts can be executed by the webhook user
RUN chown webhook:webhook /opt/scripts/email_to_webhook.py

# Create a config file for the webhook
COPY <<'EOT' /etc/postfix/webhook_config.ini
[webhook]
url = $WEBHOOK_URL
EOT

# Configure Postfix to use the webhook script
COPY <<'EOT' /etc/postfix/main.cf
# Basic Postfix configuration for a local MTA
smtpd_banner = $myhostname ESMTP $mail_name
biff = no
append_dot_mydomain = no
readme_directory = no

# Network configuration
inet_interfaces = all
inet_protocols = ipv4
myhostname = mail.example.com
mydomain = example.com
myorigin = $mydomain
mydestination = $myhostname, localhost.$mydomain, localhost, $mydomain
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128 172.0.0.0/8 10.0.0.0/8 192.168.0.0/16 100.64.0.0/10
relay_domains =

# Configure for local delivery with a pipe to our webhook script
mailbox_command =
mailbox_size_limit = 0
recipient_delimiter = +
home_mailbox = Maildir/

# Default transport
default_transport = webhook

# Configure transport maps
transport_maps = hash:/etc/postfix/transport

# Log file
maillog_file = /var/log/mail.log

# Restrictions
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
EOT

# Create transport map
COPY <<'EOT' /etc/postfix/transport
* webhook:
EOT

# Create master.cf entry for webhook transport
COPY <<'EOT' /etc/postfix/master.cf
# Regular Postfix services
smtp      inet  n       -       y       -       -       smtpd
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxywrite
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
postlog unix-dgram n  -       n       -       1       postlogd

# Custom webhook transport
webhook unix  -       n       n       -       -       pipe
  flags=Fq user=webhook argv=/opt/scripts/email_to_webhook.py
EOT

# Configure Supervisor
COPY <<'EOT' /etc/supervisor/conf.d/postfix.conf
[program:postfix]
command=/usr/sbin/postfix start-fg
autostart=true
autorestart=true
stdout_logfile=/var/log/supervisor/postfix.log
stderr_logfile=/var/log/supervisor/postfix_err.log
priority=20
EOT

# Create startup script
COPY <<'EOT' /entrypoint.sh
#!/bin/bash
set -e

# Update postfix configuration if WEBHOOK_URL is provided
if [ -n "$WEBHOOK_URL" ]; then
    echo "Using webhook URL: $WEBHOOK_URL"
    sed -i "s|\$WEBHOOK_URL|$WEBHOOK_URL|g" /etc/postfix/webhook_config.ini
else
    echo "Warning: WEBHOOK_URL environment variable not set"
    sed -i "s|\$WEBHOOK_URL|http://localhost:8080/webhook|g" /etc/postfix/webhook_config.ini
fi

# Update transport maps
postmap /etc/postfix/transport

# Define default networks
MYNETWORKS_DEFAULT="127.0.0.0/8 [::1]/128 172.16.0.0/12 10.0.0.0/8 192.168.0.0/16 100.64.0.0/10"

# Use provided PUBLIC_IP if set, otherwise use just the defaults
if [ -n "$PUBLIC_IP" ]; then
    echo "Adding public IP to mynetworks: $PUBLIC_IP"
    postconf -e "mynetworks = $MYNETWORKS_DEFAULT $PUBLIC_IP"
else
    echo "No PUBLIC_IP provided, using default networks only"
    postconf -e "mynetworks = $MYNETWORKS_DEFAULT"
fi

# Apply the setting
postconf -e "mynetworks = $MYNETWORKS"

# Create log directory for supervisor
mkdir -p /var/log/supervisor

# Start all services
exec /usr/bin/supervisord -n
EOT

RUN chmod +x /entrypoint.sh

# Create required directories
RUN mkdir -p /var/spool/postfix/pid /var/spool/postfix/dev

# Expose SMTP port
EXPOSE 25

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]