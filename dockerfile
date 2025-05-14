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

# Install webhook handler dependencies and Apprise
RUN pip3 install --no-cache-dir requests apprise pyyaml

# Create directory for email script and config
RUN mkdir -p /opt/scripts /etc/apprise

# Create python script to handle emails and forward via Apprise
COPY <<'EOT' /opt/scripts/email_to_apprise.py
#!/usr/bin/env python3
import sys
import email
import json
import os
import apprise
import yaml
import re
from email.parser import Parser
from base64 import b64encode
import configparser

# Load INI configuration from file (for backward compatibility)
config = configparser.ConfigParser()
config.read('/etc/postfix/apprise_config.ini')

# Get notification URLs from configuration
NOTIFICATION_URLS = config.get('apprise', 'urls', fallback='')

# Path to YAML config file
YAML_CONFIG_PATH = '/etc/apprise/config.yml'

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

# Prepare message content for notification
if 'text/plain' in email_data['body']:
    body_content = email_data['body']['text/plain']
elif 'text/html' in email_data['body']:
    body_content = email_data['body']['text/html']
else:
    body_content = "Email received with no text content"

# Prepare notification title
title = f"Email: {email_data['subject']}"

# Create an Apprise instance
apobj = apprise.Apprise()

# Function to extract username from email address
def get_username_from_email(email_address):
    match = re.match(r'^([^@]+)@', email_address)
    if match:
        return match.group(1)
    return None

# Check if a YAML config file exists and try to use it
yaml_config_exists = os.path.isfile(YAML_CONFIG_PATH)
target_tag = None

if yaml_config_exists:
    try:
        with open(YAML_CONFIG_PATH, 'r') as f:
            yaml_config = yaml.safe_load(f)
        
        # Get the recipient address for tag matching
        to_address = email_data['to']
        
        # First try exact match with the full email address
        if to_address in yaml_config.get('configs', {}):
            target_tag = to_address
        else:
            # Extract username from email and try to match that
            username = get_username_from_email(to_address)
            if username and username in yaml_config.get('configs', {}):
                target_tag = username
                
        if target_tag:
            print(f"Using config tag: {target_tag}")
            
            # Get the tag's configuration
            tag_config = yaml_config['configs'][target_tag]
            
            # Add all URLs for this tag
            if 'urls' in tag_config and isinstance(tag_config['urls'], list):
                for url in tag_config['urls']:
                    apobj.add(url)
                    
            # Check for custom templates in the 'mailrise' section
            if 'mailrise' in tag_config:
                mailrise_config = tag_config['mailrise']
                
                # Use custom title template if provided
                if 'title_template' in mailrise_config:
                    # Simple template substitution for ${body}, ${subject}, etc.
                    title_template = mailrise_config['title_template']
                    title = title_template.replace('${subject}', email_data['subject'])
                    title = title.replace('${body}', body_content[:50] + '...' if len(body_content) > 50 else body_content)
                    title = title.replace('${from}', email_data['from'])
                    
                # Use custom body template if provided
                if 'body_template' in mailrise_config:
                    body_template = mailrise_config['body_template']
                    if body_template == "":
                        # Empty template means don't include body
                        body_content = ""
                    else:
                        body_content = body_template.replace('${subject}', email_data['subject'])
                        body_content = body_content.replace('${body}', body_content)
                        body_content = body_content.replace('${from}', email_data['from'])
                        
                # Use specified body format
                if 'body_format' in mailrise_config:
                    # This would be used with notify() but we're handling it as a template parameter
                    pass
            
    except Exception as e:
        print(f"Error processing YAML config: {str(e)}")

# If no servers were added from YAML, fall back to URLs from INI config
if not apobj.servers and NOTIFICATION_URLS:
    for url in NOTIFICATION_URLS.split(','):
        url = url.strip()
        if url:
            apobj.add(url)

# If still no notification services, try webhook fallback
if not apobj.servers:
    print("No notification services configured.")
    # If webhook URL is defined, fall back to the original webhook approach
    webhook_url = config.get('webhook', 'url', fallback='')
    if webhook_url:
        import requests
        try:
            response = requests.post(
                webhook_url,
                json=email_data,
                headers={'Content-Type': 'application/json'}
            )
            print(f"Email sent to webhook fallback. Status code: {response.status_code}")
            sys.exit(0)
        except Exception as e:
            print(f"Error sending to webhook fallback: {str(e)}")
            sys.exit(1)
    else:
        print("No notification services or fallback configured.")
        sys.exit(1)

# Create detailed message
message = f"""
From: {email_data['from']}
To: {email_data['to']}
Date: {email_data['date']}

{body_content}
"""

# Send the notification
result = apobj.notify(
    body=message,
    title=title
)

if result:
    print("Notification sent successfully")
    sys.exit(0)
else:
    print("Failed to send notification")
    sys.exit(1)
EOT

# Make sure the script is executable
RUN chmod +x /opt/scripts/email_to_apprise.py

# Add a webhook user
RUN useradd -r -s /bin/false webhook

# Make sure the scripts can be executed by the webhook user
RUN chown webhook:webhook /opt/scripts/email_to_apprise.py

# Create a config file for Apprise
COPY <<'EOT' /etc/postfix/apprise_config.ini
[apprise]
# Multiple URLs can be separated by commas
urls = $APPRISE_URLS

[webhook]
# Fallback webhook URL (used if no apprise URLs are configured)
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
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
relay_domains =

# Configure for local delivery with a pipe to our webhook script
mailbox_command =
mailbox_size_limit = 0
recipient_delimiter = +
home_mailbox = Maildir/

# Default transport
default_transport = apprise

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
* apprise:
EOT

# Create master.cf entry for apprise transport
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

# Custom apprise transport
apprise unix  -       n       n       -       -       pipe
  flags=Fq user=webhook argv=/opt/scripts/email_to_apprise.py
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

# Update apprise configuration
if [ -n "$APPRISE_URLS" ]; then
    echo "Using Apprise URLs: $APPRISE_URLS"
    sed -i "s|\$APPRISE_URLS|$APPRISE_URLS|g" /etc/postfix/apprise_config.ini
else
    echo "No individual Apprise URLs set"
    sed -i "s|\$APPRISE_URLS||g" /etc/postfix/apprise_config.ini
fi

# Check for config file mounted at /config/posthook.yml
if [ -f "/config/posthook.yml" ]; then
    echo "Found YAML config file, copying to /etc/apprise/config.yml"
    cp /config/posthook.yml /etc/apprise/config.yml
fi

# Update webhook fallback configuration if provided
if [ -n "$WEBHOOK_URL" ]; then
    echo "Using webhook fallback URL: $WEBHOOK_URL"
    sed -i "s|\$WEBHOOK_URL|$WEBHOOK_URL|g" /etc/postfix/apprise_config.ini
else
    echo "No webhook fallback URL configured"
    sed -i "s|\$WEBHOOK_URL||g" /etc/postfix/apprise_config.ini
fi

# Update transport maps
postmap /etc/postfix/transport

# Define default localhost networks
LOCALHOST_NETWORKS="127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128"

# Start with localhost networks as absolute minimum
MYNETWORKS="$LOCALHOST_NETWORKS"

# If SUPPORTED_NETWORKS is provided, append those
if [ -n "$SUPPORTED_NETWORKS" ]; then
    echo "Adding additional networks to mynetworks: $SUPPORTED_NETWORKS"
    MYNETWORKS="$MYNETWORKS $SUPPORTED_NETWORKS"
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

# Create a volume for configuration
VOLUME ["/config"]

# Expose SMTP port
EXPOSE 25

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]
