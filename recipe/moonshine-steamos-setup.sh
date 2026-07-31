#!/usr/bin/env bash
# ShellCheck 0.11 misidentifies helper functions after argument parsing as forward declarations.
# shellcheck disable=SC2218
set -euo pipefail

readonly WRAPPER_DIR=/opt/moonshine-pixi
readonly WRAPPER_PATH=${WRAPPER_DIR}/start-moonshine.sh
readonly SERVICE_PATH=/etc/systemd/system/moonshine@.service
readonly UDEV_PATH=/etc/udev/rules.d/60-moonshine.rules
readonly MODULES_PATH=/etc/modules-load.d/moonshine.conf
readonly SYSUSERS_PATH=/etc/sysusers.d/moonshine.conf
readonly VULKAN_PATH=/etc/vulkan/implicit_layer.d/VkLayer_moonshine_wsi.json
readonly POLKIT_PATH=/etc/polkit-1/rules.d/50-moonshine-inhibit-sleep.rules
readonly ATOMIC_UPDATE_DIR=/etc/atomic-update.conf.d
readonly ATOMIC_UPDATE_PATH=${ATOMIC_UPDATE_DIR}/moonshine.conf
readonly PIXI_SERVICE_EXECSTART='ExecStart=/opt/moonshine-pixi/start-moonshine.sh /home/%i/.config/moonshine/config.toml'
SETUP_TMPDIR=

cleanup() {
  if [[ -n ${SETUP_TMPDIR:-} ]]; then
    rm -rf -- "$SETUP_TMPDIR"
  fi
}
trap cleanup EXIT

info() { printf ':: %s\n' "$*"; }
step() { printf '  -> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

print_help() {
  cat <<'EOF'
moonshine-steamos-setup — configure a Pixi or Conda Moonshine installation for SteamOS

Usage:
  moonshine-steamos-setup [OPTIONS]

Options:
  --uninstall      Remove the SteamOS integration (not the Pixi/Conda environment)
  --user USER      Configure moonshine@USER (default: current user)
  --enable         Enable the service on boot (default: prompt)
  --no-enable      Do not enable the service
  --start          Start the service after setup (default: prompt)
  --no-start       Do not start the service
  --linger         Enable lingering for headless use (default: prompt)
  --no-linger      Do not change lingering
  --dry-run        Validate inputs and show all planned changes without using sudo
  -h, --help       Show this message

Run this command as the normal target user, not with sudo. The command uses the
CONDA_PREFIX supplied by Pixi's global executable trampoline and invokes sudo
only for system integration changes.
EOF
}

shell_quote() {
  printf '%q' "$1"
}

print_command() {
  local arg
  printf '    '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

confirm() {
  local question=$1 default=$2 answer

  if [[ -t 0 ]]; then
    if [[ $default == true ]]; then
      read -r -p "${question} [Y/n] " answer
      answer=${answer:-Y}
    else
      read -r -p "${question} [y/N] " answer
      answer=${answer:-N}
    fi
  else
    if [[ $default == true ]]; then
      answer=Y
    else
      answer=N
    fi
    step "${question} ${answer} (non-interactive default)" >&2
  fi

  if [[ $answer =~ ^[Yy]$ ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

render_wrapper() {
  local source=$1 destination=$2 binary=$3 line replaced=false

  : > "$destination"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == 'exec /usr/bin/moonshine "$@"' ]]; then
      printf 'exec %q "$@"\n' "$binary" >> "$destination"
      replaced=true
    else
      printf '%s\n' "$line" >> "$destination"
    fi
  done < "$source"

  [[ $replaced == true ]] || die "could not patch Moonshine binary path in $source"
  chmod 0755 "$destination"
}

render_service() {
  local source=$1 destination=$2 line replaced=false

  : > "$destination"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == 'ExecStart=/usr/bin/start-moonshine.sh /home/%i/.config/moonshine/config.toml' ]]; then
      printf 'ExecStart=/opt/moonshine-pixi/start-moonshine.sh /home/%%i/.config/moonshine/config.toml\n' >> "$destination"
      replaced=true
    else
      printf '%s\n' "$line" >> "$destination"
    fi
  done < "$source"

  [[ $replaced == true ]] || die "could not patch ExecStart in $source"
  chmod 0644 "$destination"
}

render_vulkan_manifest() {
  local source=$1 destination=$2 library_path=$3 line before after replaced=false
  local escaped_library_path
  escaped_library_path=$(json_escape "$library_path")

  : > "$destination"
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *'/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so'* ]]; then
      before=${line%%/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so*}
      after=${line#*/usr/lib/moonshine/vulkan-layers/libmoonshine_wsi.so}
      printf '%s%s%s\n' "$before" "$escaped_library_path" "$after" >> "$destination"
      replaced=true
    else
      printf '%s\n' "$line" >> "$destination"
    fi
  done < "$source"

  [[ $replaced == true ]] || die "could not patch library_path in $source"
  chmod 0644 "$destination"
}

verify_existing_installation() {
  local binary=$1 expected_wrapper_exec
  printf -v expected_wrapper_exec 'exec %q "$@"' "$binary"

  if [[ -e $SERVICE_PATH ]] && ! grep -Fqx -- "$PIXI_SERVICE_EXECSTART" "$SERVICE_PATH"; then
    die "existing service is not managed by Moonshine's Pixi setup; remove the previous Moonshine integration first: $SERVICE_PATH"
  fi

  if [[ -e $WRAPPER_PATH ]] && ! grep -Fqx -- "$expected_wrapper_exec" "$WRAPPER_PATH"; then
    die "existing Pixi setup points to a different environment; run its setup helper with --uninstall first: $WRAPPER_PATH"
  fi
}

run_sudo() {
  print_command sudo "$@"
  sudo "$@"
}

try_sudo() {
  print_command sudo "$@"
  if ! sudo "$@"; then
    warn "command failed and was ignored: $(shell_quote "$1")"
  fi
}

main() {
  local UNINSTALL=false
  local DRY_RUN=false
  local HELP=false
  local ENABLE_ON_BOOT=
  local START_NOW=
  local LINGER=
  local TARGET_USER=
  local CURRENT_USER TARGET_UID TARGET_HOME PASSWD_ENTRY PREFIX BINARY LIBRARY
  local SHARE_DIR START_TEMPLATE SERVICE_TEMPLATE UDEV_TEMPLATE MODULES_TEMPLATE
  local SYSUSERS_TEMPLATE VULKAN_TEMPLATE POLKIT_TEMPLATE ATOMIC_UPDATE_TEMPLATE
  local SERVICE template

while [[ $# -gt 0 ]]; do
  case $1 in
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --user)
      if [[ $# -lt 2 ]]; then
        printf 'error: --user requires a user name\n' >&2
        return 1
      fi
      TARGET_USER=$2
      shift 2
      ;;
    --enable)
      ENABLE_ON_BOOT=true
      shift
      ;;
    --no-enable)
      ENABLE_ON_BOOT=false
      shift
      ;;
    --start)
      START_NOW=true
      shift
      ;;
    --no-start)
      START_NOW=false
      shift
      ;;
    --linger)
      LINGER=true
      shift
      ;;
    --no-linger)
      LINGER=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      HELP=true
      shift
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      return 1
      ;;
  esac
done

if [[ $HELP == true ]]; then
  print_help
  return 0
fi

[[ $EUID -ne 0 ]] || die "do not run with sudo; run as the normal target user"
[[ $(uname -s) == Linux ]] || die "Moonshine SteamOS setup requires Linux"
[[ $(uname -m) == x86_64 ]] || die "Moonshine only supports Linux x86-64"

CURRENT_USER=$(id -un)
TARGET_USER=${TARGET_USER:-$CURRENT_USER}
TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null) || die "user '$TARGET_USER' does not exist"
[[ $TARGET_UID -ne 0 ]] || die "the target user must not be root"
getent group "$TARGET_USER" >/dev/null 2>&1 || die "user '$TARGET_USER' must have a same-named group for Group=%i"
PASSWD_ENTRY=$(getent passwd "$TARGET_USER") || die "could not resolve account details for '$TARGET_USER'"
IFS=: read -r _ _ _ _ _ TARGET_HOME _ <<< "$PASSWD_ENTRY"
[[ $TARGET_HOME == "/home/$TARGET_USER" ]] || die "user '$TARGET_USER' must use /home/$TARGET_USER because the service template uses /home/%i"

PREFIX=${CONDA_PREFIX:-}
[[ -n $PREFIX ]] || die "CONDA_PREFIX is not set; run this command through Pixi or from an activated Conda environment"
[[ $PREFIX == /* ]] || die "CONDA_PREFIX must be an absolute path: $PREFIX"
[[ $PREFIX != *[[:cntrl:]]* ]] || die "CONDA_PREFIX must not contain control characters"
while [[ $PREFIX == */ ]]; do
  PREFIX=${PREFIX%/}
done
[[ -n $PREFIX ]] || die "CONDA_PREFIX must not be the filesystem root"

BINARY=${PREFIX}/bin/moonshine
LIBRARY=${PREFIX}/lib/moonshine/vulkan-layers/libmoonshine_wsi.so
SHARE_DIR=${PREFIX}/share/moonshine
START_TEMPLATE=${SHARE_DIR}/start-moonshine.sh
SERVICE_TEMPLATE=${SHARE_DIR}/moonshine@.service
UDEV_TEMPLATE=${SHARE_DIR}/60-moonshine.rules
MODULES_TEMPLATE=${SHARE_DIR}/moonshine-modules.conf
SYSUSERS_TEMPLATE=${SHARE_DIR}/moonshine-sysusers.conf
VULKAN_TEMPLATE=${SHARE_DIR}/VkLayer_moonshine_wsi.json
POLKIT_TEMPLATE=${SHARE_DIR}/50-moonshine-inhibit-sleep.rules
ATOMIC_UPDATE_TEMPLATE=${SHARE_DIR}/moonshine-atomic-update.conf
SERVICE=moonshine@${TARGET_USER}.service
verify_existing_installation "$BINARY"

if [[ $UNINSTALL == false ]]; then
  [[ -x $BINARY ]] || die "expected executable is missing: $BINARY"
  [[ -r $LIBRARY ]] || die "expected WSI library is missing: $LIBRARY"
  for template in \
    "$START_TEMPLATE" \
    "$SERVICE_TEMPLATE" \
    "$UDEV_TEMPLATE" \
    "$MODULES_TEMPLATE" \
    "$SYSUSERS_TEMPLATE" \
    "$VULKAN_TEMPLATE" \
    "$POLKIT_TEMPLATE" \
    "$ATOMIC_UPDATE_TEMPLATE"; do
    [[ -r $template ]] || die "expected integration template is missing: $template"
  done

  if [[ $TARGET_USER != "$CURRENT_USER" ]]; then
    if [[ $DRY_RUN == true ]]; then
      step "Would verify that $TARGET_USER can traverse and read $PREFIX"
    else
      command -v sudo >/dev/null 2>&1 || die "sudo not found"
      sudo -u "$TARGET_USER" test -x "$PREFIX" || die "user '$TARGET_USER' cannot traverse $PREFIX"
      sudo -u "$TARGET_USER" test -x "$BINARY" || die "user '$TARGET_USER' cannot execute $BINARY"
      sudo -u "$TARGET_USER" test -r "$LIBRARY" || die "user '$TARGET_USER' cannot read $LIBRARY"
    fi
  fi

  SETUP_TMPDIR=$(mktemp -d)
  render_wrapper "$START_TEMPLATE" "$SETUP_TMPDIR/start-moonshine.sh" "$BINARY"
  render_service "$SERVICE_TEMPLATE" "$SETUP_TMPDIR/moonshine@.service"
  render_vulkan_manifest "$VULKAN_TEMPLATE" "$SETUP_TMPDIR/VkLayer_moonshine_wsi.json" "$LIBRARY"
fi

if [[ $UNINSTALL == false ]]; then
  if [[ -z $ENABLE_ON_BOOT ]]; then
    ENABLE_ON_BOOT=$(confirm "Enable $SERVICE on boot?" true)
  fi
  if [[ -z $START_NOW ]]; then
    START_NOW=$(confirm "Start $SERVICE after setup?" true)
  fi
  if [[ -z $LINGER ]]; then
    if command -v loginctl >/dev/null 2>&1 && loginctl show-user "$TARGET_USER" -p Linger 2>/dev/null | grep -qx 'Linger=yes'; then
      LINGER=false
      step "Lingering is already enabled for $TARGET_USER"
    else
      LINGER=$(confirm "Enable lingering for $TARGET_USER?" true)
    fi
  fi
fi

info "$([[ $UNINSTALL == true ]] && printf 'Removing' || printf 'Installing') Moonshine SteamOS integration"
printf '  Prefix: %s\n' "$PREFIX"
printf '  User: %s\n' "$TARGET_USER"

if [[ $UNINSTALL == false ]]; then
  printf '  Moonshine binary: %s\n' "$BINARY"
  printf '  WSI library: %s\n' "$LIBRARY"
  printf '  Wrapper: %s\n' "$WRAPPER_PATH"
  printf '  Service: %s\n' "$SERVICE_PATH"
  printf '  Udev rules: %s\n' "$UDEV_PATH"
  printf '  Modules-load config: %s\n' "$MODULES_PATH"
  printf '  Sysusers config: %s\n' "$SYSUSERS_PATH"
  printf '  Vulkan manifest: %s (library_path: %s)\n' "$VULKAN_PATH" "$LIBRARY"
  printf '  Polkit rules: %s\n' "$POLKIT_PATH"
  printf '  Templates: validated and rendered successfully\n'
  if [[ -d $ATOMIC_UPDATE_DIR ]]; then
    printf '  SteamOS keep-list: %s\n' "$ATOMIC_UPDATE_PATH"
  else
    printf '  SteamOS keep-list: skipped (%s does not exist)\n' "$ATOMIC_UPDATE_DIR"
  fi
  printf '  Enable service: %s\n' "$ENABLE_ON_BOOT"
  printf '  Start service: %s\n' "$START_NOW"
  printf '  Enable lingering: %s\n' "$LINGER"
  printf '  Privileged apply commands:\n'
  print_command sudo systemctl daemon-reload
  print_command sudo systemd-sysusers
  print_command sudo udevadm control --reload
  print_command sudo udevadm trigger
  print_command sudo modprobe uinput
  print_command sudo modprobe uhid
  print_command sudo systemctl reload-or-restart polkit.service
  if [[ $LINGER == true ]]; then
    print_command sudo loginctl enable-linger "$TARGET_USER"
  fi
  if [[ $ENABLE_ON_BOOT == true && $START_NOW == true ]]; then
    print_command sudo systemctl enable --now "$SERVICE"
  elif [[ $ENABLE_ON_BOOT == true ]]; then
    print_command sudo systemctl enable "$SERVICE"
  elif [[ $START_NOW == true ]]; then
    print_command sudo systemctl start "$SERVICE"
  fi
else
  printf '  Stop and disable: %s\n' "$SERVICE"
  printf '  Remove wrapper: %s\n' "$WRAPPER_PATH"
  printf '  Remove integration files:\n'
  printf '    %s\n' \
    "$SERVICE_PATH" \
    "$UDEV_PATH" \
    "$MODULES_PATH" \
    "$SYSUSERS_PATH" \
    "$VULKAN_PATH" \
    "$POLKIT_PATH" \
    "$ATOMIC_UPDATE_PATH"
  printf '  Preserve Pixi/Conda prefix: %s\n' "$PREFIX"
  printf '  Preserve standalone installation: /opt/moonshine\n'
  printf '  Lingering: unchanged\n'
  printf '  Privileged service/reload commands:\n'
  print_command sudo systemctl stop "$SERVICE"
  print_command sudo systemctl disable "$SERVICE"
  print_command sudo systemctl daemon-reload
  print_command sudo udevadm control --reload
  print_command sudo udevadm trigger
  print_command sudo systemctl reload-or-restart polkit.service
fi

if [[ $DRY_RUN == true ]]; then
  info "Dry run complete; no files or services were changed and sudo was not invoked"
  exit 0
fi

command -v sudo >/dev/null 2>&1 || die "sudo not found"
sudo -v

if [[ $UNINSTALL == true ]]; then
  try_sudo systemctl stop "$SERVICE"
  try_sudo systemctl disable "$SERVICE"
  run_sudo rm -f \
    "$SERVICE_PATH" \
    "$UDEV_PATH" \
    "$MODULES_PATH" \
    "$SYSUSERS_PATH" \
    "$VULKAN_PATH" \
    "$POLKIT_PATH" \
    "$ATOMIC_UPDATE_PATH" \
    "$WRAPPER_PATH"
  try_sudo rmdir "$WRAPPER_DIR"
  run_sudo systemctl daemon-reload
  try_sudo udevadm control --reload
  try_sudo udevadm trigger
  try_sudo systemctl reload-or-restart polkit.service
  info "Moonshine SteamOS integration removed"
  exit 0
fi

run_sudo install -d -m 0755 \
  "$WRAPPER_DIR" \
  /etc/systemd/system \
  /etc/udev/rules.d \
  /etc/modules-load.d \
  /etc/sysusers.d \
  /etc/vulkan/implicit_layer.d \
  /etc/polkit-1/rules.d
run_sudo install -m 0755 "$SETUP_TMPDIR/start-moonshine.sh" "$WRAPPER_PATH"
run_sudo install -m 0644 "$SETUP_TMPDIR/moonshine@.service" "$SERVICE_PATH"
run_sudo install -m 0644 "$UDEV_TEMPLATE" "$UDEV_PATH"
run_sudo install -m 0644 "$MODULES_TEMPLATE" "$MODULES_PATH"
run_sudo install -m 0644 "$SYSUSERS_TEMPLATE" "$SYSUSERS_PATH"
run_sudo install -m 0644 "$SETUP_TMPDIR/VkLayer_moonshine_wsi.json" "$VULKAN_PATH"
run_sudo install -m 0644 "$POLKIT_TEMPLATE" "$POLKIT_PATH"
if [[ -d $ATOMIC_UPDATE_DIR ]]; then
  run_sudo install -m 0644 "$ATOMIC_UPDATE_TEMPLATE" "$ATOMIC_UPDATE_PATH"
fi

run_sudo systemctl daemon-reload
try_sudo systemd-sysusers
try_sudo udevadm control --reload
try_sudo udevadm trigger
try_sudo modprobe uinput
try_sudo modprobe uhid
try_sudo systemctl reload-or-restart polkit.service

if [[ $LINGER == true ]]; then
  try_sudo loginctl enable-linger "$TARGET_USER"
fi

if [[ $ENABLE_ON_BOOT == true && $START_NOW == true ]]; then
  run_sudo systemctl enable --now "$SERVICE"
elif [[ $ENABLE_ON_BOOT == true ]]; then
  run_sudo systemctl enable "$SERVICE"
elif [[ $START_NOW == true ]]; then
  run_sudo systemctl start "$SERVICE"
fi

info "Moonshine SteamOS integration installed"
if [[ $START_NOW != true ]]; then
  step "Start when ready: sudo systemctl start $SERVICE"
fi
step "Status: systemctl status $SERVICE"
step "Re-run moonshine-steamos-setup after package upgrades that change integration templates"
}

main "$@"
