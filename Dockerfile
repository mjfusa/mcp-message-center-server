FROM node:20-alpine

WORKDIR /repo/mcp-message-center-server

COPY package.json package-lock.json ./
RUN npm ci --include=dev

COPY tsconfig.json ./
COPY src ./src
COPY scripts ./scripts

# Vendored OpenAPI spec used during build-time schema generation.
COPY openapi ./openapi

RUN npm run build && npm prune --omit=dev

ENV PORT=8080
EXPOSE 8080

CMD ["node", "dist/server.js"]
