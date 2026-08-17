FROM node:20-alpine
RUN apk add --no-cache nginx gettext
WORKDIR /app
COPY nginx.conf.template entrypoint.sh ./
RUN chmod +x entrypoint.sh
CMD ["./entrypoint.sh"]
