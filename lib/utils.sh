#!/usr/bin/env bash
# lib/utils.sh — shared helper functions for aiway installer

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Printers ─────────────────────────────────────────────────────────────────
print_ok() {
    echo -e "${GREEN}  [ok]${RESET} $*"
}

print_error() {
    echo -e "${RED}  [error]${RESET} $*" >&2
}

print_warn() {
    echo -e "${YELLOW}  [warn]${RESET} $*"
}

print_step() {
    echo -e "\n${CYAN}${BOLD}==> $*${RESET}"
}

print_info() {
    echo -e "${DIM}       $*${RESET}"
}

# ── Root check ───────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        echo -e "  Try: ${BOLD}sudo bash $0${RESET}"
        exit 1
    fi
}

# ── OS detection ─────────────────────────────────────────────────────────────
# Sets globals: OS_ID  OS_VERSION_ID  OS_CODENAME
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "/etc/os-release not found — cannot detect OS."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"

    case "$OS_ID" in
        ubuntu)
            local major
            major=$(echo "$OS_VERSION_ID" | cut -d. -f1)
            if (( major < 20 )); then
                print_error "Ubuntu 20.04+ is required (detected $OS_VERSION_ID)."
                exit 1
            fi
            ;;
        debian)
            local major
            major=$(echo "$OS_VERSION_ID" | cut -d. -f1)
            if (( major < 11 )); then
                print_error "Debian 11+ is required (detected $OS_VERSION_ID)."
                exit 1
            fi
            ;;
        *)
            print_error "Unsupported OS: $OS_ID. Only Ubuntu 20.04+ and Debian 11+ are supported."
            exit 1
            ;;
    esac

    print_ok "OS: $PRETTY_NAME"
}

# ── Command presence helper ───────────────────────────────────────────────────
has_cmd() {
    command -v "$1" &>/dev/null
}

# ── Spinner for long-running commands ─────────────────────────────────────────
run_quietly() {
    local desc="$1"; shift
    local tmp
    tmp=$(mktemp)
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    echo -ne "       ${DIM}${desc}...${RESET} "

    "$@" >"$tmp" 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r       ${DIM}${desc}${RESET} ${CYAN}${frames[$i]}${RESET}"
        i=$(( (i+1) % ${#frames[@]} ))
        sleep 0.1
    done

    wait "$pid"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        echo -e "\r  ${GREEN}[ok]${RESET} ${desc}"
    else
        echo -e "\r  ${RED}[fail]${RESET} ${desc}"
        echo -e "\n${RED}--- command output ---${RESET}"
        cat "$tmp"
        echo -e "${RED}----------------------${RESET}"
        rm -f "$tmp"
        return $rc
    fi
    rm -f "$tmp"
}
