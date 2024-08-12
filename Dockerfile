FROM node:22-alpine

WORKDIR /app

EXPOSE 8000

COPY package*.json ./
RUN npm ci

COPY . .

CMD [ "node", "index.js"]

