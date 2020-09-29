FROM ruby:2.5-alpine as dev
RUN apk add --no-cache \
        make \
        pkgconfig \
        build-base \
        autoconf \
        nodejs \
        yarn \
        mariadb-dev

RUN mkdir /application
WORKDIR /application
COPY Gemfile /application/Gemfile
COPY Gemfile.lock /application/Gemfile.lock
RUN bundle install

# Add a script to be executed every time the container starts.
COPY docker-entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/docker-entrypoint.sh
ENTRYPOINT ["sh", "docker-entrypoint.sh"]
EXPOSE 3000

# Start the main process.
CMD ["rails", "server", "-b", "0.0.0.0"]

FROM dev as prod

COPY . /application