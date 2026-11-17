# Operacao Sentinel - watchdog (somente biblioteca padrao do Python)
FROM python:3.12-alpine
RUN adduser -D -u 10002 sentinel
WORKDIR /app
COPY watchdog.py .
USER sentinel
ENV PYTHONUNBUFFERED=1 PORTA=9100
EXPOSE 9100
HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=3 \
  CMD python -c "import urllib.request,os;urllib.request.urlopen('http://127.0.0.1:%s/health' % os.environ.get('PORTA','9100'), timeout=2)"
CMD ["python", "/app/watchdog.py"]
