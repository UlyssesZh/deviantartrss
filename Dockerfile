FROM ruby:4.0-slim

WORKDIR /app

RUN apt-get update && apt-get install -y build-essential
COPY . .
RUN bundle install

ENV RACK_ENV production
ENV DEVIANTARTRSS_DB /data/data.db
ENV DEVIANTARTRSS_COOKIE_JAR /data/cookies.txt

CMD ["bundle", "exec", "./main.rb"]
