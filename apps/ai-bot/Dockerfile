# syntax=docker/dockerfile:1.7

FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS run
WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/install/bin:$PATH \
    PYTHONPATH=/install/lib/python3.12/site-packages
COPY --from=build /install /install
COPY ai_bot/ ./ai_bot/

# python:3.12-slim ships a `nobody` user but it can't write anywhere; create
# a dedicated UID 1000 like our other services so K8s runAsUser:1000 matches.
RUN groupadd -g 1000 app && useradd -u 1000 -g app -s /usr/sbin/nologin app
USER 1000:1000
EXPOSE 8080
CMD ["uvicorn", "ai_bot.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]
