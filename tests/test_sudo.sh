#!/bin/bash
# sudo flow test for btrfs-snapman-cli as an ordinary user. Creates users, writes
# /etc/sudoers.d and /etc/btrfs-snapman/config.toml, so run it as root ONLY on a
# disposable Ubuntu 24.04 machine or container, with the btrfs-snapman-common and
# btrfs-snapman-cli packages installed (the sudo rules name the installed helpers).
# Password prompts are answered through tmux. Usage: sudo tests/test_sudo.sh
set -u
command -v tmux >/dev/null || { echo "tmux is not installed"; exit 2; }
[ -x /usr/libexec/btrfs-snapman/snapman-query ] || { echo "install the packages first"; exit 2; }
WORK=$(mktemp -d); chmod 755 "$WORK"
MNT=$WORK/mnt
ETC=/etc/btrfs-snapman
PW="Pw-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
USR=snaptest; OPS=snapop                # an admin with a password, and a snapman-group member
T="tmux -L snapman-sudo-$$"
pass=0; fail=0

cleanup() {
  $T kill-server 2>/dev/null
  rm -f /etc/sudoers.d/btrfs-snapman /etc/sudoers.d/00-snapman-test
  pkill -u "$USR"; pkill -u "$OPS"; sleep 0.5
  userdel -r "$USR" 2>/dev/null; userdel -r "$OPS" 2>/dev/null; groupdel snapman 2>/dev/null
  [ -f "$WORK/config.toml.orig" ] && cp "$WORK/config.toml.orig" "$ETC/config.toml"
  rm -f "$ETC"/parents.d/*-approve-me.toml
  umount "$MNT" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- users, filesystem, config
# The admin gets a rule of their own rather than the sudo group, whose rules vary by machine
# (a test VM often has "%sudo ... NOPASSWD: ALL"). In sudoers the last match wins, so it
# must sort before btrfs-snapman, as /etc/sudoers' own %sudo rule does.
useradd -m -s /bin/bash "$USR" && echo "$USR:$PW" | chpasswd || exit 2
echo "$USR ALL=(ALL:ALL) ALL" > /etc/sudoers.d/00-snapman-test && chmod 440 /etc/sudoers.d/00-snapman-test
if sudo -l -U "$USR" | grep -q NOPASSWD; then echo "$USR gets NOPASSWD here; can't test"; exit 2; fi
groupadd snapman && useradd -m -s /bin/bash -G snapman "$OPS" && echo "$OPS:$PW" | chpasswd || exit 2
truncate -s 1G "$WORK/fs.img" && mkfs.btrfs -q "$WORK/fs.img" && mkdir -p "$MNT" \
  && mount -o loop "$WORK/fs.img" "$MNT" || exit 2
btrfs -q subvolume create "$MNT/@vol" >/dev/null
mkdir -p "$MNT/snapshots/vol" "$MNT/approve-me"
cp "$ETC/config.toml" "$WORK/config.toml.orig"
cat > "$ETC/config.toml" <<EOF
[defaults]
name_format = "{volume}_{timestamp}_{label}"
timestamp_format = "%Y-%m-%d_%H-%M-%S"

[[volume]]
name = "vol"
path = "$MNT/@vol"
snapshot_dir = "$MNT/snapshots/vol"
EOF

# ---------------------------------------------------------------- test helpers
# as USER CMD : start CMD as USER in a fresh tmux pane (its own tty, so its own sudo timestamp)
as() {
  $T kill-server 2>/dev/null; sleep 0.3
  # --pty: plain "su -c" detaches from the terminal, and sudo then can't ask
  $T new-session -d -x 100 -y 30 -s t "su --pty - $1 -c '$2; echo EXIT=\$?; sleep 600'"
}
keys() { $T send-keys -t t "$@"; sleep 0.3; }
password() { $T send-keys -t t -l "$1"; $T send-keys -t t Enter; sleep 0.5; }
screen() { $T capture-pane -p -S -200 -t t; }
wait_for() { local i; for i in $(seq 80); do screen | grep -qE -- "$1" && return 0; sleep 0.1; done; return 1; }
prompts() { screen | grep -c "password for"; }
# answer N [PASSWORD] : wait for the Nth password prompt in this pane, then type the password
answer() {
  local i; for i in $(seq 80); do
    [ "$(prompts)" -ge "$1" ] && { password "${2:-$PW}"; return 0; }; sleep 0.1
  done; return 1
}
# answer_prompt : wait until sudo's prompt is the last line on screen, then type the password
answer_prompt() {
  local i; for i in $(seq 80); do
    screen | grep -v '^ *$' | tail -1 | grep -q "password for" && { password "$PW"; return 0; }
    sleep 0.1
  done; return 1
}
assert() {
  local desc=$1; shift
  if "$@"; then pass=$((pass+1)); echo "PASS  $desc"
  else fail=$((fail+1)); echo "FAIL  $desc"; screen | grep -v '^ *$' | tail -15 | sed 's/^/      /'; fi
}
seen() { assert "$1" wait_for "$2"; }
snaps() { ls "$MNT/snapshots/vol" | wc -l; }
no_password_in_ps() { ! ps -eo args | grep -v grep | grep -qF -- "$PW"; }

# ---------------------------------------------------------------- default sudoers (%sudo with password)
out=$(su - "$USR" -c "btrfs-snapman-cli snapshot vol </dev/null 2>&1; echo EXIT=\$?")
assert "no terminal, no timestamp: exit 3"          grep -q "EXIT=3" <<<"$out"
assert "  with a clear message"                     grep -q "no terminal to ask on" <<<"$out"

as "$USR" "btrfs-snapman-cli snapshot vol first"
seen "first call: sudo -v asks"                     "password for $USR"
assert "  password not in the process list"         no_password_in_ps
answer 1
seen "  then the snapshot is made"                  "^vol_.*_first$"
seen "  exit 0"                                     "EXIT=0"
assert "  on disk"                                  [ "$(snaps)" = 1 ]
assert "  password never in the process list"       no_password_in_ps
uid=$(id -u "$USR")
assert "journal names the user via SUDO_UID"        eval 'journalctl -t btrfs-snapman --since "-2min" | grep -q "uid=$uid snapshot"'

as "$USR" "btrfs-snapman-cli snapshot vol a; btrfs-snapman-cli snapshot vol b; btrfs-snapman-cli list vol"
answer 1
seen "timestamp reused: two snapshots, one prompt"  "EXIT=0"
assert "  exactly one prompt"                       [ "$(prompts)" = 1 ]
assert "  both on disk"                             [ "$(snaps)" = 3 ]

as "$USR" "btrfs-snapman-cli list && btrfs-snapman-cli add-location $MNT/approve-me && btrfs-snapman-cli remove-location $MNT/approve-me --yes"
answer 1
seen "list uses the password once"                  "^vol +$MNT/@vol"
assert "manage verbs ask again despite the timestamp" answer 2
seen "  add-location done"                          "Approved $MNT/approve-me"
assert "  and again for remove-location"            answer 3
seen "  removed, exit 0"                            "EXIT=0"
assert "  three prompts in all"                     [ "$(prompts)" = 3 ]

as "$USR" "sudo -k; btrfs-snapman-cli snapshot vol wrong"
for i in 1 2 3; do answer $i "not-the-password"; done
seen "wrong password three times: exit 3"          "EXIT=3"
assert "  nothing made"                             [ "$(snaps)" = 3 ]

# ---------------------------------------------------------------- TUI: first prompt before curses, expiry, manage
as "$USR" "sudo -k; btrfs-snapman-cli"
seen "TUI: password asked before curses starts"     "password for $USR"
assert "  not yet full screen"                      eval '! screen | grep -q "q quit"'
answer 1
seen "  then the TUI starts"                        "q quit"
assert "  not 'running as root'"                    eval '! screen | grep -q "running as root"'
su - "$USR" -c "sudo -K"                        # the timestamp runs out mid-session
keys s; wait_for "Snapshot “vol”"; keys Enter
seen "expired timestamp: curses steps aside, sudo asks" "sudo needs your password"
answer_prompt
seen "  retried once: snapshot created, TUI back"   "Created vol_"
assert "  on disk"                                  [ "$(snaps)" = 4 ]
keys a; wait_for "Approve new location"; keys C-u
$T send-keys -t t -l "$MNT/approve-me"; keys Enter
seen "TUI manage: asks every time"                  "ask for your password every time"
keys C-c
seen "  Ctrl-C at the prompt: back in the TUI, error shown" "error: sudo authentication failed"
assert "  nothing approved"                         eval '! ls "$ETC"/parents.d/*approve-me* >/dev/null 2>&1'
keys a; wait_for "Approve new location"; keys C-u
$T send-keys -t t -l "$MNT/approve-me"; keys Enter
wait_for "ask for your password every time"; answer_prompt
seen "  with the password: approved"                "Approved $MNT/approve-me"
keys q
seen "  quits with 0"                               "EXIT=0"

# ---------------------------------------------------------------- the sudoers example
EXAMPLE=/usr/share/doc/btrfs-snapman-cli/examples/sudoers.example
assert "sudoers.example passes visudo -c"           eval 'visudo -c -f "$EXAMPLE" >/dev/null'
# As shipped, but with its %sudo line for our admin (see above)
sed "s/^%sudo /$USR /" "$EXAMPLE" > /etc/sudoers.d/btrfs-snapman && chmod 440 /etc/sudoers.d/btrfs-snapman
assert "  installed, visudo -c still passes"        eval 'visudo -c >/dev/null'
out=$(su - "$USR" -c "sudo -k; btrfs-snapman-cli list </dev/null 2>&1; echo EXIT=\$?")
assert "NOPASSWD listing: works with no terminal"   eval 'grep -q "EXIT=0" <<<"$out" && grep -q "^vol " <<<"$out"' || echo "$out"
as "$OPS" "btrfs-snapman-cli snapshot vol ops && btrfs-snapman-cli new-volume x $MNT"
answer 1
seen "snapman group: snapshot allowed"             "^vol_.*_ops$"
answer 2
seen "  volume management refused by sudo: exit 1" "EXIT=1"
assert "  with sudo's reason"                      eval 'screen | grep -q "not allowed to execute"'
assert "password never in the process list"         no_password_in_ps

echo; echo "passed=$pass failed=$fail"
[ $fail -eq 0 ]
