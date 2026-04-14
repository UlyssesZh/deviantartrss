# deviantartrss

A very simple HTTP server to provide RSS feed for user galleries on DeviantArt.

## Features

Advantages compared to the [official RSS API](https://www.deviantart.com/developers/rss) of DeviantArt:

- Better title and icon.
- Use large image for thumbnail.
- Filter blurred images (images behind paywall).

## Deploy

On bare metal:

```shell
bundle install
RACK_ENV=production PORT=80 bundle exec ./main.rb
```

With Docker Compose:

```yaml
services:
  app:
    image: ulysseszhan/deviantartrss
    container_name: deviantartrss
    restart: unless-stopped
    environment:
      RACK_ENV: production
      DEVIANTARTRSS_COOKIES: userinfo=xxx; td=xxx; auth=xxx; auth_secure=xxx
      DEVIANTARTRSS_BASE_URL: https://deviantartrss.mydomain
    ports:
      - '80:4567'
    volumes:
      - ./data:/data
```

Change `80` to the port on which you want it to be hosted.

The cookies are necessary to view adult images.

## Usage

Suppose you hosted it on `deviantartrss.example.com`, and then you can simply access
`http://deviantartrss.example.com/spyed`.

## License

MIT.
