FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y \
        libyaml-dev \
        build-essential \
        libffi-dev \
        --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir apprise pyyaml

# Copy app code
COPY main.py /app/main.py
COPY posthook.conf /app/posthook.conf

WORKDIR /app

# Use main.py as the entrypoint (e.g., from Postfix pipe)
ENTRYPOINT ["python", "main.py"]
