FROM node:22-alpine

WORKDIR /app

EXPOSE 3000

COPY package*.json ./
RUN npm ci

COPY . .

CMD [ "node", "index.js"]
