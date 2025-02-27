# Posthook
Posthook is a lightweight container that forwards emails to a webhook. 

I built this container because I wanted to be able to route emails from applications that only support email notifications (for example Unifi Network Controller) to other applications like n8n. 

The container runs Postfix as the SMTP server then routes the email to the webhook using a python script. 

# Setup
By default this container will route emails sent from the localhost. If you want to send emails from outside of the localhost make sure to include an IP or IP range using the SUPPORTED_NETWORKS environment variable.

Important notes:
* The WEBHOOK_URL is required, if not provided it will fall back to http://localhost:8080/webhook
* The SUPPORTED_NETWORKS are optional and require a netmask, make sure to add it in the same format as the docker compose sample below or remove it if not required

### Public IP Warning
This container supports setting the public IP to 0.0.0.0/0 to allow any IP to send it messages. Be very careful doing so as this will make it an open relay that anyone can use. 

## Docker Compose
```
version: "3.4"

services:
  posthook:
    image: ghcr.io/hucknz/posthook:latest
    container_name: posthook
    ports:
      - 25:25
    environment:
      - WEBHOOK_URL=https://yourdomain.tld/ # Required
      - SUPPORTED_NETWORKS=xxx.xxx.xxx.xxx/xx xxx.xxx.xxx.xxx/xx
    restart: unless-stopped
```