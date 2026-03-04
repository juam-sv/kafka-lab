FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpq-dev gcc libc6-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create and switch to a non-root user
RUN useradd -m appuser && chown -R appuser /app
USER appuser

CMD ["python", "producer.py"]
