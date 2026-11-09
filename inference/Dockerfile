FROM python:3.13.9-slim

ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app

COPY models ./models
COPY server.py .

USER nobody
EXPOSE 8000
CMD ["python", "server.py"]
