# Use Python 3.12 slim image (project targets Python 3.12+)
FROM python:3.12-slim-bookworm

WORKDIR /app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Create non-root user for security
RUN groupadd -r appgroup && useradd -r -g appgroup appuser && chown -R appuser:appgroup /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN if [ -f config.ini ]; then rm config.ini; fi

# Ensure appuser owns the copied files after optional removal
RUN chown -R appuser:appgroup /app

USER appuser
ENTRYPOINT ["python", "-m", "src.main"]
CMD ["--conf", "config.ini"]