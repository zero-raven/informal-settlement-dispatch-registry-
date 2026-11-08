FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev
COPY src ./src
EXPOSE 8090
ENV PORT=8090
ENV DB_PATH=/data/registry.db
CMD ["node", "src/server.js"]
