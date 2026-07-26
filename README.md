[![Build static rTorrent binaries (release)](https://github.com/m3r3nix/rtorrent-static-binary/actions/workflows/release.yml/badge.svg)](https://github.com/m3r3nix/rtorrent-static-binary/actions/workflows/release.yml)
# Static rTorrent Binaries

This repository provides fully static rTorrent binaries built from the original source code of [rakshasa/rtorrent](https://github.com/rakshasa/rtorrent).

The goal is to provide portable Linux binaries that can run on most distributions without manually compiling rTorrent or installing runtime library dependencies.

## Why Static Binaries?

A fully static binary includes the required libraries inside the executable itself.

This makes it useful for:

- Minimal Linux systems
- Containers
- NAS/server environments
- Older distributions
- Systems where compiling from source is inconvenient
- Deployments where you want a single portable executable

## Supported Platforms

Prebuilt binaries are provided for:

- `amd64`
- `arm64`

## Binary Variants

Each release may include multiple rTorrent variants.

| Variant | Description |
|---|---|
| <code>rtorrent&#8209;linux&#8209;amd64</code> <br> <code>rtorrent&#8209;linux&#8209;arm64</code> | Modern rTorrent build with built-in `tinyxml2` XML-RPC support |

Use the default binary unless you specifically need XML-RPC compatibility.

## Installation

1. Download the binary for your architecture and preferred variant from the latest release: [here](https://github.com/m3r3nix/rtorrent-static-binary/releases).

2. Make it executable:

```sh
chmod +x rtorrent-linux-*
```

3. Move it into your PATH with the simplified filename `rtorrent`:
```sh
sudo mv rtorrent-linux-* /usr/local/bin/rtorrent
```

4. Verify it works:
```sh
rtorrent -h
```

## Notes
These binaries are built directly from upstream rTorrent release sources.

This repository does NOT modify rTorrent functionality. It only automates the build process and publishes static Linux binaries.

For rTorrent usage, configuration, and upstream documentation, refer to the original project: [rakshasa/rtorrent](https://github.com/rakshasa/rtorrent)
