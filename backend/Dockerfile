FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build
FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN apk add --no-cache ca-certificates su-exec && npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY migrations ./migrations
COPY docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh && mkdir -p /app/storage/firmware /app/storage/apps && chown -R node:node /app/storage
ENTRYPOINT ["/app/docker-entrypoint.sh"]
EXPOSE 3000
CMD ["node", "dist/server.js"]
