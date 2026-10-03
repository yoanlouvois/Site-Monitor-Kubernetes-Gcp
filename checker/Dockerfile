FROM python:3.12-slim

WORKDIR /app

COPY common/requirements.txt common/requirements.txt
COPY checker/requirements.txt checker/requirements.txt
RUN pip install --no-cache-dir -r common/requirements.txt -r checker/requirements.txt

COPY common/ common/
COPY checker/ checker/

RUN useradd --system app
USER app

CMD ["python", "-m", "checker.main"]