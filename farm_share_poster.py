"""
FarmTracker - Farm Share Poster
Watches farm_tracker/share/ for .lua files, posts to Discord via webhook.
If a previous post exists for that farm, deletes it before posting the new one.

Requirements:
    pip install requests watchdog

Setup:
    1. Place this script/exe inside your farm_tracker/ folder
    2. Edit config.ini with your Discord webhook URL
    3. Run: python farm_share_poster.py
"""

import os
import re
import time
import sys
import json
import requests
import configparser
from datetime import datetime, timezone, timedelta
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# Timezone abbreviations supported in expiry tags
TZ_OFFSETS = {
    "EST": -5, "EDT": -4,
    "CST": -6, "CDT": -5,
    "MST": -7, "MDT": -6,
    "PST": -8, "PDT": -7,
    "UTC": 0,  "GMT": 0,
}

def convert_expiry_tags(content):
    """
    Replace [expiry:YYYY-MM-DD HH:MM:SS TZ] tags with Discord <t:UNIX:R> timestamps.
    Python integers are arbitrary precision — no float rounding issues.
    """
    def replace_tag(m):
        date_str = m.group(1)
        tz_str   = m.group(2)
        offset_h = TZ_OFFSETS.get(tz_str.upper(), 0)
        try:
            dt_local = datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
            dt_utc   = dt_local - timedelta(hours=offset_h)
            dt_utc   = dt_utc.replace(tzinfo=timezone.utc)
            unix     = int(dt_utc.timestamp())
            return f"<t:{unix}:R>"
        except Exception as e:
            print(f"[WARN] Could not parse expiry tag '{m.group(0)}': {e}")
            return m.group(0)

    return re.sub(r'\[expiry:(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) ([A-Z]+)\]',
                  replace_tag, content)

# ── Config ────────────────────────────────────────────────────────────────────

BASE_DIR      = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, "frozen", False) else __file__))
CONFIG_FILE   = os.path.join(BASE_DIR, "config.ini")
SHARE_FOLDER  = os.path.join(BASE_DIR, "share")
MSG_ID_FILE   = os.path.join(BASE_DIR, "message_ids.json")

def load_config():
    if not os.path.exists(CONFIG_FILE):
        print(f"[ERROR] config.ini not found at: {CONFIG_FILE}")
        input("Press Enter to exit...")
        sys.exit(1)

    config = configparser.ConfigParser()
    config.read(CONFIG_FILE, encoding="utf-8")

    webhook_url = config.get("discord", "webhook_url", fallback="").strip()

    if not webhook_url or webhook_url == "YOUR_WEBHOOK_URL_HERE":
        print("[ERROR] webhook_url is not set in config.ini")
        input("Press Enter to exit...")
        sys.exit(1)

    return webhook_url

# ── Message ID store ──────────────────────────────────────────────────────────

def load_message_ids():
    if os.path.exists(MSG_ID_FILE):
        try:
            with open(MSG_ID_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def save_message_ids(ids):
    with open(MSG_ID_FILE, "w", encoding="utf-8") as f:
        json.dump(ids, f, indent=2)

def farm_key(content):
    """Stable key from first two lines (farm name + coords)."""
    lines = content.strip().splitlines()
    key = "\n".join(lines[:2]) if len(lines) >= 2 else lines[0]
    return key.strip()

# ── Lua parser ────────────────────────────────────────────────────────────────

def extract_content(lua_text):
    match = re.search(r'content\s*=\s*"((?:[^"\\]|\\.)*)"', lua_text, re.DOTALL)
    if match:
        raw = match.group(1)
        raw = raw.replace('\\"', '"')
        raw = raw.replace('\\n', '\n')
        raw = raw.replace('\\\n', '\n')
        raw = raw.replace('\\\\', '\\')
        return raw
    return None

# ── Discord ───────────────────────────────────────────────────────────────────

def post_message(webhook_url, content):
    resp = requests.post(
        webhook_url,
        json={"content": content},
        params={"wait": "true"},
        timeout=10
    )
    resp.raise_for_status()
    return str(resp.json()["id"])

def delete_message(webhook_url, message_id):
    url = f"{webhook_url}/messages/{message_id}"
    resp = requests.delete(url, timeout=10)
    if resp.status_code == 404:
        print(f"[INFO] Previous message {message_id} already gone, skipping delete.")
    else:
        resp.raise_for_status()

# ── File handler ──────────────────────────────────────────────────────────────

class ShareHandler(FileSystemEventHandler):
    def __init__(self, webhook_url):
        self.webhook_url = webhook_url

    def on_created(self, event):
        if event.is_directory or not event.src_path.endswith(".lua"):
            return
        self.process(event.src_path)

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith(".lua"):
            return
        self.process(event.src_path)

    def process(self, filepath):
        filename = os.path.basename(filepath)
        time.sleep(0.2)

        try:
            with open(filepath, "r", encoding="utf-8") as f:
                lua_text = f.read()

            content = extract_content(lua_text)
            if not content:
                print(f"[WARN] Could not parse content from {filename}, skipping.")
                return

            content = convert_expiry_tags(content)

            message_ids = load_message_ids()
            key = farm_key(content)

            # Delete previous post for this farm if one exists
            if key in message_ids:
                print(f"[DELETE] Removing previous post for: {key.splitlines()[0]}")
                delete_message(self.webhook_url, message_ids[key])

            # Post fresh
            print(f"[POST] {key.splitlines()[0]}")
            msg_id = post_message(self.webhook_url, content)
            message_ids[key] = msg_id
            save_message_ids(message_ids)
            os.remove(filepath)
            print(f"[DONE] Posted message {msg_id}\n")

        except FileNotFoundError:
            pass  # Second event fired after file was already processed and deleted
        except requests.HTTPError as e:
            print(f"[ERROR] Discord rejected request ({e.response.status_code}): {e}")
        except requests.RequestException as e:
            print(f"[ERROR] Network error: {e}")
        except Exception as e:
            print(f"[ERROR] Failed to process {filename}: {e}")

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    webhook_url = load_config()
    os.makedirs(SHARE_FOLDER, exist_ok=True)

    print(f"FarmTracker Share Poster started.")
    print(f"Watching: {SHARE_FOLDER}\n")

    handler = ShareHandler(webhook_url)

    # Process any files already sitting in the folder
    existing = [f for f in os.listdir(SHARE_FOLDER) if f.endswith(".lua")]
    if existing:
        print(f"[INFO] Found {len(existing)} existing file(s), processing...\n")
        for filename in existing:
            handler.process(os.path.join(SHARE_FOLDER, filename))

    observer = Observer()
    observer.schedule(handler, path=SHARE_FOLDER, recursive=False)
    observer.start()

    try:
        while observer.is_alive():
            observer.join(timeout=1)
    except KeyboardInterrupt:
        print("\nStopping...")
        observer.stop()
    observer.join()

if __name__ == "__main__":
    main()
