FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV LEADERBOARD_DB=/data/leaderboard.sqlite
VOLUME /data
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
