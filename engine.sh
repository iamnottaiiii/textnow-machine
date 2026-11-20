#!/usr/bin/env bash
# TextNow machine engine. Runs on a GitHub Actions runner.
# One job only: Chrome on a virtual screen, opened straight into
# TextNow as a standalone app window, streamed through a Cloudflare
# quick tunnel. The public link is written to live.json and
# committed back to this repo. The Chrome profile is saved (AES-256
# encrypted) into the repo every minute and restored at the next
# start, when PROFILE_KEY is set, so the one TextNow login made on
# this machine is the login every future session wakes up with.
# A Save page inside the session lets the person save manually at
# any moment.
# This is the golden lab build, specialized: the same disguise
# (Eastern time, US English, WebRTC leak closed, automation tell
# off, standard fonts) that passed TextNow's Press and Hold human
# check, and the same home exit-node routing, because TextNow
# flags datacenter addresses as VPN traffic. Boot hardening comes
# from the full-computer build: the engine logs to boot.log
# (committed next to live.json on every publish), publishes its
# link as soon as the tunnel exists (before the restore and the
# Chrome start), and verifies the saved archive before restoring
# it; a failed verification boots fresh with saving held, so the
# last good archive in the repo is never overwritten by an empty
# state.

VNC_PASS="${VNC_PASS:-bjvfi-live}"
export BROWSER_REPO_DIR="$(pwd)"
export SAVE_REPO="$HOME/save-repo"
export PUB_REPO="$HOME/pub-repo"
TS_STATUS='datacenter direct'
TS_PEERS=''

# Boot log: everything the engine prints from here on also lands
# in boot.log, and the publish loop commits that file next to
# live.json, so a failed boot can be read from the repo instead
# of being locked inside the Actions log.
BOOT_LOG="$HOME/boot.log"
: > "$BOOT_LOG"
exec > >(tee -a "$BOOT_LOG") 2>&1
bootstep() { echo "[boot $(date -u +%H:%M:%SZ)] $*"; }
bootstep 'engine started'
RESTORE_STATE='none'
SAVE_ENABLED=1

sudo apt-get update -qq
sudo apt-get install -y -qq xvfb x11vnc novnc websockify openbox tint2 rsync fonts-liberation fonts-noto-core > /dev/null
if ! command -v google-chrome > /dev/null; then
  wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  sudo apt-get install -y -qq ./google-chrome-stable_current_amd64.deb > /dev/null
fi
curl -sL -o /tmp/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x /tmp/cloudflared
bootstep 'packages ready'

# Home IP routing: when TS_AUTHKEY is set, this session joins the
# tailnet and sends its traffic out through the home exit node, so
# TextNow sees the home IP instead of the datacenter's. This is the
# golden build's block: a bounded poll for an offered exit node,
# then a plain fallback to direct egress when none is offered.
# Cloudflare's edge ranges stay on the direct route (table 52) so
# the tunnel itself, which talks to those edges, stays stable.
if [ -n "$TS_AUTHKEY" ]; then
  GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
  DEV=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  curl -fsSL https://tailscale.com/install.sh | sh > /dev/null 2>&1
  sudo tailscaled > /tmp/tailscaled.log 2>&1 &
  sleep 3
  if sudo tailscale up --authkey "$TS_AUTHKEY" --hostname bjvfi-textnow --accept-dns=false > /tmp/tailscale-up.log 2>&1; then
    echo 'Joined the tailnet, looking for an exit node'
  else
    echo 'Tailnet join failed, browsing keeps the datacenter IP'
    cat /tmp/tailscale-up.log
  fi
  EXIT_IP=''
  for i in $(seq 1 12); do
    EXIT_IP=$(tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for p in (d.get("Peer") or {}).values():
    if p.get("ExitNodeOption"):
        ips = p.get("TailscaleIPs") or []
        if ips:
            print(ips[0])
            break
' 2>/dev/null)
    if [ -n "$EXIT_IP" ]; then break; fi
    sleep 5
  done
  if [ -n "$EXIT_IP" ]; then
    sudo tailscale set --exit-node "$EXIT_IP" || true
    if [ -n "$GW" ]; then
      for NET in 198.41.192.0/24 198.41.200.0/24; do
        sudo ip route add $NET via $GW dev $DEV table 52 > /dev/null 2>&1 || true
      done
    fi
    TS_STATUS="exit node $EXIT_IP"
    echo "Home IP routing on, exit node $EXIT_IP"
  else
    echo 'No exit node found on the tailnet, browsing keeps the datacenter IP'
  fi
  TS_PEERS=$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for p in (d.get('Peer') or {}).values():
    name = (p.get('HostName') or '?').strip()
    out.append(name + (' (exit offered)' if p.get('ExitNodeOption') else ''))
print(', '.join(out) if out else 'none')
" 2>/dev/null)
fi

bootstep "routing settled: $TS_STATUS"
git config user.name 'browser-bot'
git config user.email 'browser-bot@users.noreply.github.com'

# The save loop and the publish loop each get their OWN clone of
# this repo. In the old build they shared one checkout and their
# pushes kept colliding, which froze the live.json heartbeat.
# Separate clones, and each cycle starts from a fresh fetch of
# origin/main.
setup_clone() {
  local src="$BROWSER_REPO_DIR" dst="$1" url eh
  rm -rf "$dst"
  git clone -q "$src" "$dst" 2>/dev/null || return 1
  url=$(git -C "$src" remote get-url origin 2>/dev/null)
  [ -n "$url" ] && git -C "$dst" remote set-url origin "$url"
  eh=$(git -C "$src" config --get http.https://github.com/.extraheader 2>/dev/null || true)
  [ -n "$eh" ] && git -C "$dst" config http.https://github.com/.extraheader "$eh"
  git -C "$dst" config user.name 'browser-bot'
  git -C "$dst" config user.email 'browser-bot@users.noreply.github.com'
  git -C "$dst" fetch -q origin main 2>/dev/null || true
  git -C "$dst" checkout -q -B main FETCH_HEAD 2>/dev/null || git -C "$dst" checkout -q -B main 2>/dev/null || true
}
setup_clone "$SAVE_REPO" || echo 'Save clone setup failed'
setup_clone "$PUB_REPO" || echo 'Publish clone setup failed'

# The save script, shared by the auto-save and the manual Save
# page. It packs the Chrome profile into one AES-256 encrypted
# file in its own clone and pushes it. Two guards ride along from
# the hardened computer build: while the hold flag exists (set at
# boot when the saved archive failed verification) the script
# refuses, so the last good save is never overwritten; and a
# content manifest skips the push when nothing changed.
cat > $HOME/do-save.sh << 'SAVE_EOF'
#!/usr/bin/env bash
exec 9>/tmp/save.lock
if ! flock -n 9; then
  echo 'A save is already running'
  exit 3
fi
if [ -z "$PROFILE_KEY" ] && [ -f "$HOME/.browser-save-key" ]; then
  PROFILE_KEY=$(cat "$HOME/.browser-save-key")
  export PROFILE_KEY
fi
if [ -z "$PROFILE_KEY" ]; then
  echo 'Saving is not switched on'
  exit 2
fi
if [ -f "$HOME/.save-hold" ]; then
  echo 'Saving is held this session: the last good save stays untouched'
  exit 4
fi
SAVE_REPO="${SAVE_REPO:-$HOME/save-repo}"
if [ ! -d "$SAVE_REPO/.git" ]; then
  echo 'Save repo missing'
  exit 1
fi
rm -rf /tmp/prof-stage && mkdir -p /tmp/prof-stage
rsync -a \
  --exclude='*/Cache/*' --exclude='*/Code Cache/*' --exclude='*/GPUCache/*' \
  --exclude='*/Service Worker/CacheStorage/*' --exclude='*/blob_storage/*' \
  --exclude='SingletonLock' --exclude='SingletonCookie' --exclude='SingletonSocket' \
  $HOME/chrome-profile/ /tmp/prof-stage/ 2>/dev/null
MANIFEST=$(cd /tmp/prof-stage && find . -type f -o -type l | sort | xargs -r sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
if [ -n "$MANIFEST" ] && [ "$MANIFEST" = "$(cat $HOME/.profile-manifest 2>/dev/null)" ]; then
  echo 'Saved'
  exit 0
fi
cd "$SAVE_REPO" || exit 1
git fetch -q origin main 2>/dev/null || true
git reset --hard -q origin/main 2>/dev/null || true
if tar -czf - -C /tmp/prof-stage . 2>/dev/null | openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:PROFILE_KEY -out profile.tar.gz.enc 2>/dev/null; then
  git add profile.tar.gz.enc
  git commit -m 'profile save' > /dev/null 2>&1 || true
  if git push -q origin main > /dev/null 2>&1; then
    printf '%s' "$MANIFEST" > $HOME/.profile-manifest
    echo 'Saved'
    exit 0
  fi
fi
echo 'Save failed'
exit 1
SAVE_EOF
chmod +x $HOME/do-save.sh

# The key lives in a private file inside the session only, so the
# Save page can run saves without the secret in its own hands.
if [ -n "$PROFILE_KEY" ]; then
  printf '%s' "$PROFILE_KEY" > $HOME/.browser-save-key
  chmod 600 $HOME/.browser-save-key
fi

# The Save page: a tiny local web page with one big button.
cat > $HOME/save-server.py << 'PYEOF'
import os
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PAGE = """<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>Save this browser</title>
<style>body{font-family:monospace;padding:40px 24px;font-size:22px;color:#111}
button{font-size:26px;padding:20px 34px;background:#111;color:#fff;border:0;width:100%}
</style></head><body>
<p>This page saves the whole browser: the TextNow login and everything in the profile.</p>
<form method='POST' action='/save'><button type='submit'>SAVE NOW</button></form>
<p>{note}</p>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    def _send(self, note):
        body = PAGE.replace('{note}', note).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send('Auto-save also runs every minute while the machine is on.')

    def do_POST(self):
        if self.path != '/save':
            self._send('')
            return
        try:
            result = subprocess.run(['bash', os.path.expanduser('~/do-save.sh')],
                                    capture_output=True, text=True, timeout=180)
            out = (result.stdout or '') + (result.stderr or '')
        except Exception:
            out = 'failed'
        if 'Saved' in out:
            note = 'Saved. The TextNow login is packed away safely.'
        elif 'already running' in out:
            note = 'A save is already running. Give it a few seconds.'
        elif 'not switched on' in out:
            note = 'Saving is not switched on yet. It turns on with the PROFILE_KEY secret.'
        else:
            note = 'The save did not finish. The auto-save will try again soon.'
        self._send(note)

    def log_message(self, *args):
        pass

HTTPServer(('127.0.0.1', 8080), Handler).serve_forever()
PYEOF

# Until the restore runs (it sits later in the boot, after the
# first publish), live.json reports the restore as pending when a
# saved archive is waiting.
if [ -n "$PROFILE_KEY" ] && [ -f profile.tar.gz.enc ]; then
  RESTORE_STATE='pending'
fi

# The screen stack comes up before the tunnel: the tunnel points
# at the noVNC port, so the port has to exist first. Eastern time
# is part of the disguise, set before Chrome ever starts.
sudo timedatectl set-timezone America/New_York > /dev/null 2>&1 || true
export TZ=America/New_York
Xvfb :99 -screen 0 1280x800x24 > /tmp/xvfb.log 2>&1 &
sleep 2
DISPLAY=:99 openbox > /tmp/openbox.log 2>&1 &
DISPLAY=:99 tint2 > /tmp/tint2.log 2>&1 &
mkdir -p ~/.vnc
x11vnc -storepasswd "$VNC_PASS" ~/.vnc/passwd > /dev/null 2>&1
x11vnc -display :99 -rfbport 5900 -rfbauth ~/.vnc/passwd -forever -shared -bg -o /tmp/x11vnc.log
websockify --web=/usr/share/novnc 6080 localhost:5900 > /tmp/websockify.log 2>&1 &
python3 $HOME/save-server.py > /tmp/save-server.log 2>&1 &
bootstep 'screen stack up'

# Quick tunnel, a fresh random address each run. The tunnel now
# starts BEFORE the state restore and the Chrome start, and the
# first publish happens as soon as its address exists, so
# live.json goes fresh early and a later failure still leaves a
# live link and a diagnosable state in the repo. Quick tunnels do
# fail to register now and then; the attempt is retried before
# the boot gives up, and giving up still publishes (with the boot
# log) before it exits.
export CHAIN_FILE="$HOME/chain-result.txt"
URL=''
for attempt in 1 2 3; do
  bootstep "tunnel attempt $attempt"
  /tmp/cloudflared tunnel --url http://localhost:6080 --no-autoupdate --protocol http2 > /tmp/tunnel.log 2>&1 &
  TUNNEL_PID=$!
  for i in $(seq 1 22); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/tunnel.log | head -1)
    if [ -n "$URL" ]; then break; fi
    sleep 2
  done
  if [ -n "$URL" ]; then break; fi
  echo "Tunnel attempt $attempt produced no address"
  cat /tmp/tunnel.log
  kill $TUNNEL_PID > /dev/null 2>&1 || true
  sleep 5
done
if [ -z "$URL" ]; then
  echo 'Tunnel did not come up after 3 attempts'
  TUNNEL_FAILED=1
else
  echo "Tunnel is live: $URL"
fi

# Publishing writes live.json in the publish loop's own clone.
publish() {
  (
    flock -x 200
    cd "$PUB_REPO" 2>/dev/null || exit 0
    git fetch -q origin main 2>/dev/null || true
    git reset --hard -q origin/main 2>/dev/null || true
    cp "$BOOT_LOG" boot.log 2>/dev/null || true
    TUNNEL_URL="$URL" VNC_PASS="$VNC_PASS" TS_STATUS="$TS_STATUS" TS_PEERS="$TS_PEERS" CHAIN_FILE="$CHAIN_FILE" RESTORE_STATE="$RESTORE_STATE" python3 -c "
import json, os, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
base = os.environ.get('TUNNEL_URL', '')
url = base + '/vnc.html?autoconnect=true&password=' + os.environ['VNC_PASS'] + '&resize=scale' if base else ''
try:
    d = json.load(open('live.json'))
except Exception:
    d = {}
d['url'] = url
if not d.get('started'):
    d['started'] = now
d['heartbeat'] = now
d['state'] = 'live' if url else 'tunnel-failed'
d['build'] = 'textnow-machine'
d['restore'] = os.environ.get('RESTORE_STATE', '')
d['ts'] = os.environ.get('TS_STATUS', '')
d['peers'] = os.environ.get('TS_PEERS', '')
try:
    with open(os.environ['CHAIN_FILE']) as f:
        d['chain'] = f.read().strip()
except Exception:
    d['chain'] = 'pending: self-dispatch fires at 300 minutes'
try:
    import urllib.request
    d['ip'] = urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode().strip()
except Exception:
    pass
json.dump(d, open('live.json', 'w'), indent=2)
"
    git add live.json boot.log
    git commit -m 'browser live' > /dev/null 2>&1 || true
    git push -q origin main > /dev/null 2>&1 || true
  ) 200>/tmp/publish.lock
}

save_profile() {
  if [ "$SAVE_ENABLED" != "1" ]; then
    echo 'Final save held: protecting the last good archive'
    return 0
  fi
  bash $HOME/do-save.sh || true
}

publish
bootstep 'first publish done'
if [ -n "${TUNNEL_FAILED:-}" ]; then
  echo 'Boot cannot continue without a tunnel address; the failure state and boot log are published above'
  exit 1
fi

mkdir -p $HOME/chrome-profile

# Restore the saved profile, if a save exists and the key is set.
# The save file is AES-256 encrypted; without PROFILE_KEY it is
# opaque. The archive is verified BEFORE it touches the live home:
# it is decrypted to a temp file and its tar listing is read, with
# one retry. Only a verified archive is extracted and applied.
# Two layouts are understood: the current one (a profile/ folder)
# and the golden one (profile files at the top), so a save written
# by either layout restores. If verification fails, the boot
# carries on fresh with saving held for the whole session, so the
# last good archive in the repo is never overwritten.
RESTORED=0
if [ -n "$PROFILE_KEY" ] && [ -f profile.tar.gz.enc ]; then
  bootstep 'restore: verifying the saved archive before touching the live home'
  RESTORE_VERIFIED=0
  for try in 1 2; do
    rm -rf /tmp/restore /tmp/restore.tar /tmp/archive.enc
    cp profile.tar.gz.enc /tmp/archive.enc 2>/dev/null || true
    if [ -f /tmp/archive.enc ] \
       && openssl enc -d -aes-256-cbc -pbkdf2 -pass env:PROFILE_KEY -in /tmp/archive.enc -out /tmp/restore.tar 2>/tmp/decrypt.log \
       && tar -tzf /tmp/restore.tar > /dev/null 2>&1; then
      RESTORE_VERIFIED=1
      break
    fi
    echo "Restore verification failed (attempt $try)"
    cat /tmp/decrypt.log 2>/dev/null || true
    sleep 3
  done
  if [ "$RESTORE_VERIFIED" = "1" ]; then
    mkdir -p /tmp/restore
    if tar -xzf /tmp/restore.tar -C /tmp/restore 2>/dev/null; then
      if [ -d /tmp/restore/profile ]; then
        rsync -a /tmp/restore/profile/ $HOME/chrome-profile/ 2>/dev/null
      else
        rsync -a /tmp/restore/ $HOME/chrome-profile/ 2>/dev/null
      fi
      rm -f $HOME/chrome-profile/SingletonLock $HOME/chrome-profile/SingletonCookie $HOME/chrome-profile/SingletonSocket
      RESTORED=1
      RESTORE_STATE='ok'
      echo 'Saved profile restored'
    else
      echo 'Verified archive could not be extracted, starting fresh with saving held'
      RESTORE_STATE='failed-fresh-boot'
    fi
  else
    echo 'Saved profile could not be verified, starting fresh with saving held'
    RESTORE_STATE='failed-fresh-boot'
  fi
  if [ "$RESTORE_STATE" = "failed-fresh-boot" ]; then
    SAVE_ENABLED=0
    : > $HOME/.save-hold
  fi
  rm -rf /tmp/restore /tmp/restore.tar /tmp/archive.enc
fi
publish
bootstep "restore settled: $RESTORE_STATE"

# The whole point of this machine: Chrome opens straight into
# TextNow as a standalone app window, maximized, no tabs and no
# address bar. The flags are the golden disguise set, unchanged.
DISPLAY=:99 google-chrome --no-sandbox --disable-dev-shm-usage --no-first-run --start-maximized --lang=en-US --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-blink-features=AutomationControlled --user-data-dir=$HOME/chrome-profile --app=https://www.textnow.com/messaging > /tmp/chrome.log 2>&1 &
bootstep 'TextNow app window started'

# Continuous save: every minute, so the login made in this
# session is packed away almost as soon as it happens. When the
# restore failed verification, saving is held for the whole
# session: this loop never starts, the final save is skipped,
# and do-save.sh itself refuses while the hold flag exists, so
# the last good archive in the repo survives.
if [ "$SAVE_ENABLED" = "1" ]; then
  ( while true; do sleep 60; bash $HOME/do-save.sh > /dev/null 2>&1 || true; done ) > /dev/null 2>&1 &
else
  echo 'Auto-save held this session: the saved archive could not be verified at boot'
fi

# Always on: at 300 minutes this run calls the next run into
# being, so a fresh session takes over before this one ends. The
# dispatch targets the repo this session is actually running in,
# read from its own git remote, and the attempt plus its HTTP
# result are written to the chain file, which publish() puts
# into live.json.
(
  sleep 18000
  SLUG=$(git -C "$BROWSER_REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')
  AUTH=$(git -C "$BROWSER_REPO_DIR" config --get http.https://github.com/.extraheader 2>/dev/null | awk '{print $NF}')
  TOKEN=$(printf '%s' "$AUTH" | base64 -d 2>/dev/null | sed 's/^x-access-token://')
  CODE='no-token'
  if [ -n "$TOKEN" ] && [ -n "$SLUG" ]; then
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$SLUG/actions/workflows/browser.yml/dispatches" -d '{"ref":"main"}')
  fi
  printf 'dispatch to %s at %s UTC, HTTP %s' "$SLUG" "$(date -u +%FT%TZ)" "$CODE" > "$CHAIN_FILE"
  sleep 10
  publish
) > /dev/null 2>&1 &

# Keep the session alive, refreshing the heartbeat so the door
# page knows the machine is awake. The job itself is capped by
# the workflow timeout (355 minutes). The profile is saved every
# minute by its own loop, and once more at the end.
for i in $(seq 1 64); do
  sleep 300
  publish
done
save_profile
