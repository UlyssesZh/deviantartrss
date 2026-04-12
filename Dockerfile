FROM ruby:4.0-slim

WORKDIR /app

RUN apt-get update && apt-get install -y build-essential
COPY . .
RUN bundle install

ENV DEVIANTARTRSS_DB /data/data.db

CMD ["bundle", "exec", "./main.rb"]
