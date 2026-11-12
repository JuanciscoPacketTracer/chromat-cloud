FROM node:26.0.0-bookworm-slim

ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY docker-entrypoint.sh /usr/local/bin/chromat-entrypoint
RUN chmod 755 /usr/local/bin/chromat-entrypoint

EXPOSE 3000
ENTRYPOINT ["chromat-entrypoint"]
CMD ["node", "src/server.js"]
