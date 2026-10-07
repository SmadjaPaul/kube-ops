FROM python:3.11-slim AS source

ARG IMAGE_VERSION=f822b554c52676a7e75953c65e2578d9c9fa89dc

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

RUN git init /src \
    && cd /src \
    && git remote add origin https://github.com/DSS-AI/invoice-ninja-mcp.git \
    && git fetch --depth 1 origin "$IMAGE_VERSION" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "$IMAGE_VERSION"

FROM python:3.11-slim

ARG IMAGE_VERSION=f822b554c52676a7e75953c65e2578d9c9fa89dc
LABEL org.opencontainers.image.source="https://github.com/DSS-AI/invoice-ninja-mcp"
LABEL org.opencontainers.image.revision="$IMAGE_VERSION"

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY --from=source /src/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY --from=source /src/in_mcp/ ./in_mcp/
COPY --from=source /src/scripts/ ./scripts/

RUN useradd -r -u 10001 app \
    && mkdir -p /data \
    && chown app /data

USER 10001
EXPOSE 8539
CMD ["python", "-m", "in_mcp.server"]
