#!/usr/bin/env bash
# lib/utils.sh — shared helpers for aiway installer/uninstaller

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Printers ─────────────────────────────────────────────────────────────────
print_ok()    { echo -e "${GREEN}  [ok]${RESET} $*"; }
print_error() { echo -e "${RED}  [!!]${RESET} $*" >&2; }
print_warn()  { echo -e "${YELLOW}  [--]${RESET} $*"; }
print_step()  { echo -e "\n${CYAN}${BOLD}==> $*${RESET}"; }
print_info()  { echo -e "${DIM}       $*${RESET}"; }

# ── Root check ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Run as root: sudo bash $0"
        exit 1
    fi
}

# ── OS detection — sets OS_ID, OS_VERSION_ID, OS_CODENAME ────────────────────
detect_os() {
    [[ ! -f /etc/os-release ]] && { print_error "/etc/os-release not found."; exit 1; }
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    local major
    major=$(echo "$OS_VERSION_ID" | cut -d. -f1)
    case "$OS_ID" in
        ubuntu) (( major >= 20 )) || { print_error "Ubuntu 20.04+ required (got $OS_VERSION_ID)."; exit 1; } ;;
        debian) (( major >= 11 )) || { print_error "Debian 11+ required (got $OS_VERSION_ID)."; exit 1; } ;;
        *) print_error "Unsupported OS: $OS_ID. Ubuntu 20.04+ or Debian 11+ required."; exit 1 ;;
    esac
    print_ok "OS: $PRETTY_NAME"
}

# ── has_cmd ───────────────────────────────────────────────────────────────────
has_cmd() { command -v "$1" &>/dev/null; }

# ── run_quietly — spinner wrapper ─────────────────────────────────────────────
# Usage: run_quietly "Description" cmd arg1 arg2 ...
# Runs cmd in background with a spinner; prints [ok] or [fail]+output.
# Restores cursor on SIGINT/SIGTERM so the terminal isn't left broken.
run_quietly() {
    local desc="$1"; shift
    local tmp; tmp=$(mktemp)
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    # Run command in background
    "$@" >"$tmp" 2>&1 &
    local pid=$!

    # Spinner loop
    local interrupted=false
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${RESET} ${DIM}%s${RESET}" "${frames[$i]}" "$desc"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done

    wait "$pid"
    local rc=$?

    # Clear spinner line
    printf "\r%*s\r" "$(tput cols 2>/dev/null || echo 80)" ""

    if [[ $rc -eq 0 ]]; then
        print_ok "$desc"
    else
        print_error "$desc"
        echo -e "${RED}--- output ---${RESET}"
        cat "$tmp"
        echo -e "${RED}--------------${RESET}"
        rm -f "$tmp"
        return $rc
    fi
    rm -f "$tmp"
}

# ── wait_for_port_free — poll until a TCP/UDP port is no longer in use ────────
# Usage: wait_for_port_free <port> <timeout_seconds>
wait_for_port_free() {
    local port="$1"
    local timeout="${2:-10}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if ! ss -tlunH "sport = :${port}" 2>/dev/null | grep -q .; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ── port_in_use — true if anything is bound to port (TCP or UDP) ──────────────
port_in_use() {
    local port="$1"
    ss -tlunH "sport = :${port}" 2>/dev/null | grep -q .
}
