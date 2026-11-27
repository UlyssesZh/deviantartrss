# deviantartrss

A very simple HTTP server to provide RSS feed for user galleries on DeviantArt.

## Features

Uses DeviantArt's website gallery endpoint to generate RSS locally, without requesting the official RSS API.
Each feed contains up to 60 recent gallery entries,
filtered to accessible images, with titles, images, publication dates, and artwork
links.
Artist-written descriptions are not included.

Features:

- Better title and icon.
- Use large image for thumbnail.
- Filter blurred images (images behind paywall).
- Unblur adult images.

## Deploy

On bare metal:

```shell
bundle install
RACK_ENV=production PORT=80 bundle exec ./main.rb
```

To view mature images, set both `DEVIANTARTRSS_USERNAME` and
`DEVIANTARTRSS_PASSWORD` in the server environment.
If the account has two-factor authentication enabled,
also set `DEVIANTARTRSS_TOTP_KEY` to its Base32 authenticator secret.
Enable mature browsing in the account's DeviantArt settings.
For example:

```shell
DEVIANTARTRSS_USERNAME=your-username
DEVIANTARTRSS_PASSWORD=your-password
DEVIANTARTRSS_TOTP_KEY=your-base32-authenticator-secret
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
