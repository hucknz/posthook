import sys
import email
from email import policy
from apprise import Apprise, AppriseConfig
import string

# Load full Apprise config
ac = AppriseConfig()
ac.add('posthook.conf')

# Read email from stdin
raw_email = sys.stdin.read()
msg = email.message_from_string(raw_email, policy=policy.default)

sender = msg.get('From', 'unknown').lower()
subject = msg.get('Subject', '(No Subject)')

# Get plain text body
if msg.is_multipart():
    for part in msg.walk():
        if part.get_content_type() == 'text/plain':
            body = part.get_content()
            break
    else:
        body = "(No plain text body)"
else:
    body = msg.get_content()

# Determine which config to use based on sender
sender_key = sender.split('@')[0]  # e.g., 'basic_assistant'
apobj = Apprise(ac)

# Format custom templates if available
entry = ac.find(tag=sender_key)
if not entry:
    entry = ac.find(tag="default")
    if not entry:
        print(f"No matching tag or default for sender: {sender}")
        sys.exit(0)

config = entry[0]  # Get the first match
title = subject
body_text = body

if "mailrise" in config:
    mailrise = config["mailrise"]
    title_template = string.Template(mailrise.get("title_template", "${subject}"))
    body_template = string.Template(mailrise.get("body_template", "${body}"))
    title = title_template.safe_substitute(subject=subject, body=body)
    body_text = body_template.safe_substitute(subject=subject, body=body)

apobj.notify(
    title=title,
    body=body_text,
    tag=sender_key
)
