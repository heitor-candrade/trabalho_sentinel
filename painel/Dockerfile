# Operacao Sentinel - painel (FastAPI + uvicorn). Versoes fixadas (regra do enunciado: nada de "latest").
FROM python:3.12-slim-bookworm
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py pagina.html .
RUN useradd --system --uid 10002 --no-create-home painel
USER painel
EXPOSE 8085
HEALTHCHECK --interval=5s --timeout=3s --start-period=3s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8085/health', timeout=2).status == 200 else 1)"]
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8085", "--no-access-log"]
