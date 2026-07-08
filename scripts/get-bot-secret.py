#!/usr/bin/env python3
"""Extract a value from a pacto-bot-api TOML config for a given bot identity.

Usage:
    scripts/get-bot-secret.py <config-file> <bot-id> <key>

<key> can be one of: npub, nsec

Exits non-zero if the bot or key is not found.
"""
import sys
import tomllib


def main():
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <config-file> <bot-id> <key>", file=sys.stderr)
        return 1

    config_path = sys.argv[1]
    bot_id = sys.argv[2]
    key = sys.argv[3]

    try:
        with open(config_path, "rb") as f:
            config = tomllib.load(f)
    except FileNotFoundError:
        return 1
    except Exception as exc:
        print(f"error reading config: {exc}", file=sys.stderr)
        return 1

    bots = config.get("bots", [])
    if not isinstance(bots, list):
        return 1

    for bot in bots:
        if bot.get("id") != bot_id:
            continue
        if key == "npub":
            value = bot.get("npub")
        elif key == "nsec":
            signing = bot.get("signing", {})
            if isinstance(signing, dict):
                value = signing.get("nsec")
            else:
                value = None
        else:
            print(f"error: unsupported key '{key}'", file=sys.stderr)
            return 1
        if value:
            print(value)
            return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
