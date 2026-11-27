# deviantartrss

A very simple HTTP server to provide RSS feed for user galleries on DeviantArt.

## Features

Advantages compared to the [official RSS API](https://www.deviantart.com/developers/rss) of DeviantArt:

- Better title and icon.
- Use large image for thumbnail.
- Filter blurred images (images behind paywall).
- Unblur adult images.

## Deploy

On bare metal:

Set `DEVIANTARTRSS_USERNAME` and `DEVIANTARTRSS_PASSWORD` in the server environment.
If the account has two-factor authentication enabled,
also set `DEVIANTARTRSS_TOTP_KEY` to its Base32 authenticator secret.
Enable mature browsing in the account's DeviantArt settings if you want to view adult images.
For example:

```shell
DEVIANTARTRSS_USERNAME=your-username
DEVIANTARTRSS_PASSWORD=your-password
DEVIANTARTRSS_TOTP_KEY=your-base32-authenticator-secret
```

Then run:

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
      DEVIANTARTRSS_USERNAME: your-username
      DEVIANTARTRSS_PASSWORD: your-password
      DEVIANTARTRSS_TOTP_KEY: your-base32-authenticator-secret
    ports:
      - '80:4567'
    volumes:
      - ./data:/data
```

Change `80` to the port on which you want it to be hosted.

## Usage

Suppose you hosted it on `deviantartrss.example.com`, and then you can simply access
`http://deviantartrss.example.com/spyed`.

## License

MIT.
