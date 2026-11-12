FROM node:26.0.0-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
ENTRYPOINT ["/workspace/tests/smoke/client-entrypoint.sh"]
