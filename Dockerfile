FROM ruby:3.4-slim

WORKDIR /app

RUN apt-get update && apt-get install -y build-essential
COPY . .
RUN bundle install

CMD ["bundle", "exec", "./main.rb"]
