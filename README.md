# AstroHome installer

One-line bootstrap for [AstroHome](https://github.com/alome007) — a household AI assistant.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/alome007/astrohome-installer/main/install.sh | bash
```

You'll be prompted for:

- Your GitHub username (the owner of the private `astrohome-core` repo)
- A GitHub Personal Access Token with `Contents: Read` on that repo
- A Cloudflare-managed domain (optional — for public access via tunnel)

## Non-interactive

```bash
ASTROHOME_OWNER=<gh-user> \
GH_TOKEN=ghp_xxx \
ASTROHOME_DOMAIN=example.com \
ASTROHOME_NONINTERACTIVE=1 \
curl -fsSL https://raw.githubusercontent.com/alome007/astrohome-installer/main/install.sh | bash
```

## Source

This file is auto-mirrored from the private `astrohome-core` repo. Don't
edit here; submit changes to the source repo.

