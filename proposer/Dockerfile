FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ARG PORT=3000
EXPOSE ${PORT} 8000

CMD ["python", "app.py"]