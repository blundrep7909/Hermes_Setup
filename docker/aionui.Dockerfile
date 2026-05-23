FROM python:3.12-slim AS hermes-builder
RUN pip install --no-cache-dir hermes-agent[acp]

FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=hermes-builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=hermes-builder /usr/local/bin/hermes /usr/local/bin/hermes

WORKDIR /app
RUN npm install -g bun \
    && git clone https://github.com/iOfficeAI/AionUi.git . \
    && bun install \
    && bun run build

EXPOSE 3001
CMD ["bun", "run", "start"]
