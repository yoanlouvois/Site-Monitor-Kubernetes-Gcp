FROM python:3.12-slim

WORKDIR /app

COPY common/requirements.txt common/requirements.txt
COPY api/requirements.txt api/requirements.txt
RUN pip install --no-cache-dir -r common/requirements.txt -r api/requirements.txt

COPY common/ common/
COPY api/ api/

# Ne pas tourner en root (bonne pratique de sécurité)
RUN useradd --system app
USER app

EXPOSE 8000
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]