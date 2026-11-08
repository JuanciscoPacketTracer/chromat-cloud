FROM node:26.0.0-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

COPY src ./src

USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
