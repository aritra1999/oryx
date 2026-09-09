FROM python:3.12-alpine

RUN apk add --no-cache dcron

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Install crontab
RUN crontab /app/crontab

CMD ["crond", "-f", "-l", "2"]
