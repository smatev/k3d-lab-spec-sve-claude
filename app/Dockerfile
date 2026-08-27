# Multi-stage: the build tools never reach the runtime image.

FROM python:3.14.7-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY main.py ./

# Precompile here, because the runtime image runs with a read-only root filesystem and
# PYTHONDONTWRITEBYTECODE=1 — it could not write .pyc files even if it wanted to.
RUN python -m compileall -q /opt/venv/lib /app


FROM python:3.14.7-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:${PATH}"

# A fixed non-root UID, so the chart's runAsUser matches something real. No home
# directory, no login shell.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app/main.py /app/main.py

WORKDIR /app
USER 10001:10001

EXPOSE 8000

# No shell form: exec form means PID 1 is python itself, so it receives SIGTERM directly
# rather than having a shell swallow it. Graceful shutdown depends on this.
ENTRYPOINT ["python", "main.py"]
