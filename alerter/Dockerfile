FROM python:3.12-slim

# Affiche les print() immédiatement dans les logs
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY common/requirements.txt common/requirements.txt
COPY alerter/requirements.txt alerter/requirements.txt
RUN pip install --no-cache-dir -r common/requirements.txt -r alerter/requirements.txt

COPY common/ common/
COPY alerter/ alerter/

RUN useradd --system app
USER app

CMD ["python", "-m", "alerter.main"]