FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY . .

ENV PORT=9001
ENV STATE_FILE=/app/data/state.json

RUN mkdir -p /app/data

EXPOSE 9001

CMD ["npm", "start"]
