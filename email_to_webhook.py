#!/usr/bin/env python3
import os
import time
import requests

WEBHOOK_URL = os.getenv("WEBHOOK_URL", "https://your-webhook-url.com")
MAIL_DIR = "/var/mail"

def process_email(email_path):
    """Reads email content and sends it to a webhook."""
    with open(email_path, "r") as file:
        email_content = file.read()

    response = requests.post(WEBHOOK_URL, json={"email": email_content})
    print(f"Sent email to webhook, status: {response.status_code}")

    os.remove(email_path)  # Delete processed email

while True:
    emails = [f for f in os.listdir(MAIL_DIR) if f.endswith(".txt")]
    
    for email in emails:
        process_email(os.path.join(MAIL_DIR, email))

    time.sleep(5)  # Check for new emails every 5 seconds