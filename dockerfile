FROM debian:bullseye-slim

# Install required packages
RUN apt-get update && apt-get install -y \
    postfix \
    mailutils \
    python3 \
    python3-pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy email processing script
COPY email_to_webhook.py /app/email_to_webhook.py
RUN chmod +x /app/email_to_webhook.py

# Copy Postfix config files
COPY main.cf /etc/postfix/main.cf
COPY aliases /etc/aliases
RUN newaliases

# Start both services
COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
