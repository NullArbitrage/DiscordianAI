#!/usr/bin/env bash
# DiscordianAI Launcher — portable, venv-aware, pyenv-friendly
#
# Suitable for manual execution, crontab, or systemd (foreground mode).
# Always changes directory to the project root before launching,
# so Python can find the `src` package regardless of how it's invoked.
#
# Usage:
#   ./discordian.sh                          # foreground, default config
#   ./discordian.sh -d                       # daemon mode (background)
#   ./discordian.sh -c bot.ini               # custom config file
#   ./discordian.sh -f /path/to/project      # project directory
#   ./discordian.sh -d -c production.ini -f /opt/discordianai
#
# Python resolution order:
#   1. pyenv-managed python3 (preferred — version-pinned, reproducible)
#   2. Project-local .venv/bin/python3
#   3. Shell-activated venv ($VIRTUAL_ENV)
#   4. System python3
#
# If no venv exists, one is created automatically in the project directory.

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
CONFIG_FILE="bot.ini"
DAEMON_MODE=false
PROJECT_DIR="${SCRIPT_DIR}"

# ── Argument parsing ──────────────────────────────────────────────────
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -d|--daemon) DAEMON_MODE=true; shift ;;
        -c|--config)
            [[ -n "${2:-}" && ! "$2" =~ ^- ]] || { echo "ERROR: -c requires a config file argument" >&2; exit 1; }
            CONFIG_FILE="$2"; shift 2 ;;
        -f|--folder)
            [[ -n "${2:-}" && ! "$2" =~ ^- ]] || { echo "ERROR: -f requires a directory argument" >&2; exit 1; }
            PROJECT_DIR="$(realpath "$2")"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-d] [-c config.ini] [-f /path/to/project]"
            echo "  -d, --daemon   Run in background (daemon mode)"
            echo "  -c, --config   Configuration file (default: bot.ini)"
            echo "  -f, --folder   Project directory (default: script location)"
            echo "  -h, --help     Show this help message"
            exit 0 ;;
        *) shift ;;
    esac
done

VENV_DIR="${PROJECT_DIR}/.venv"
PID_FILE="${PROJECT_DIR}/.bot.pid"
LOG_FILE="${PROJECT_DIR}/bot.log"

# ── Logging ───────────────────────────────────────────────────────────
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }

# ── 1. Change to project directory ────────────────────────────────────
#     Cron runs from $HOME — Python needs CWD inside the project to
#     find the `src` package via `-m src.main`.
cd "${PROJECT_DIR}"
log "Working directory: $(pwd)"

# ── 2. Resolve Python interpreter ─────────────────────────────────────
#     Priority: pyenv → project venv → shell venv → system python3
resolve_python() {
    # pyenv first — version-pinned, reproducible
    if command -v pyenv >/dev/null 2>&1; then
        local pyenv_python
        pyenv_python="$(pyenv which python3 2>/dev/null || true)"
        if [[ -n "${pyenv_python}" && -x "${pyenv_python}" ]]; then
            echo "${pyenv_python}"
            return 0
        fi
    fi
    # Project-local venv
    if [[ -x "${VENV_DIR}/bin/python3" ]]; then
        echo "${VENV_DIR}/bin/python3"
        return 0
    fi
    # Shell-activated venv (VIRTUAL_ENV is set)
    if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python3" ]]; then
        echo "${VIRTUAL_ENV}/bin/python3"
        return 0
    fi
    # System python3
    local sys_python
    sys_python="$(command -v python3 2>/dev/null || true)"
    if [[ -n "${sys_python}" ]]; then
        echo "${sys_python}"
        return 0
    fi
    return 1
}

PYTHON="$(resolve_python)" || {
    log "ERROR: No python3 found. Install Python 3.12+ or create a venv."
    exit 1
}
log "Using python3: ${PYTHON} ($(${PYTHON} --version 2>&1))"

# ── 3. Verify Python version (3.12+) ──────────────────────────────────
py_major="$(${PYTHON} -c 'import sys; print(sys.version_info[0])')"
py_minor="$(${PYTHON} -c 'import sys; print(sys.version_info[1])')"
if [[ "${py_major}" -lt 3 ]] || [[ "${py_major}" -eq 3 && "${py_minor}" -lt 12 ]]; then
    log "ERROR: Python 3.12+ required, found ${py_major}.${py_minor}"
    exit 1
fi

# ── 4. Bootstrap venv if missing ──────────────────────────────────────
if [[ ! -d "${VENV_DIR}" || ! -x "${VENV_DIR}/bin/python3" ]]; then
    log "Creating venv at ${VENV_DIR} using ${PYTHON}..."
    "${PYTHON}" -m venv "${VENV_DIR}" || {
        log "ERROR: Failed to create venv. Check Python installation."
        exit 1
    }
    log "Installing dependencies..."
    if [[ -f "${PROJECT_DIR}/requirements.txt" ]]; then
        "${VENV_DIR}/bin/pip" install -r "${PROJECT_DIR}/requirements.txt" --quiet 2>/dev/null || {
            log "WARNING: pip install reported issues, retrying with verbose output..."
            "${VENV_DIR}/bin/pip" install -r "${PROJECT_DIR}/requirements.txt"
        }
    elif [[ -f "${PROJECT_DIR}/pyproject.toml" ]]; then
        "${VENV_DIR}/bin/pip" install -e "${PROJECT_DIR}" --quiet 2>/dev/null || {
            log "WARNING: pip install reported issues, retrying with verbose output..."
            "${VENV_DIR}/bin/pip" install -e "${PROJECT_DIR}"
        }
    else
        log "WARNING: No requirements.txt or pyproject.toml found — dependencies may be missing."
    fi
    log "Venv bootstrapped successfully."
    # Re-resolve to the venv python
    PYTHON="${VENV_DIR}/bin/python3"
fi

# ── 5. Dependency check ───────────────────────────────────────────────
log "Checking core dependencies..."
if ! "${PYTHON}" -c "import discord; import openai; import httpx" 2>/dev/null; then
    log "ERROR: Missing core dependencies (discord.py, openai, or httpx)."
    log "Repair with: ${VENV_DIR}/bin/pip install -r requirements.txt"
    exit 1
fi
log "✓ All core dependencies available"

# ── 6. Kill existing instances (cron restart) ──────────────────────────
log "Stopping any existing instances..."
my_pid="$$"

# By PID file
if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}")"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
        log "Stopping previous instance (PID ${old_pid})"
        kill "${old_pid}" 2>/dev/null || true
        local_wait=0
        while kill -0 "${old_pid}" 2>/dev/null && [[ ${local_wait} -lt 10 ]]; do
            sleep 1; ((local_wait++))
        done
        if kill -0 "${old_pid}" 2>/dev/null; then
            log "Force-killing unresponsive process ${old_pid}"
            kill -9 "${old_pid}" 2>/dev/null || true
        fi
    fi
    rm -f "${PID_FILE}"
fi

# Stragglers matching the bot pattern (but not ourselves)
for pid in $(pgrep -f "src.main.*--conf" 2>/dev/null || true); do
    if [[ "${pid}" != "${my_pid}" ]]; then
        log "Killing stray process ${pid}"
        kill "${pid}" 2>/dev/null || true
    fi
done

# ── 7. Build and launch the command ────────────────────────────────────
COMMAND="${PYTHON} -m src.main --conf ${CONFIG_FILE}"
if [[ "${PROJECT_DIR}" != "$(pwd)" ]]; then
    COMMAND="${COMMAND} --folder ${PROJECT_DIR}"
fi
log "Command: ${COMMAND}"

if [[ "${DAEMON_MODE}" == true ]]; then
    # ── Daemon mode: background, redirect to log file ──────────────────
    log "Daemon mode: logging to ${LOG_FILE}"
    nohup ${COMMAND} >> "${LOG_FILE}" 2>&1 &
    bot_pid=$!
    echo "${bot_pid}" > "${PID_FILE}"
    log "Bot started in background (PID ${bot_pid})"

    # Health check: give it a few seconds to crash on startup
    sleep 3
    if kill -0 "${bot_pid}" 2>/dev/null; then
        log "✓ Bot is running (PID ${bot_pid})"
    else
        log "ERROR: Bot crashed on startup. Check ${LOG_FILE}"
        rm -f "${PID_FILE}"
        exit 1
    fi
else
    # ── Foreground mode: systemd or manual ─────────────────────────────
    echo "$$" > "${PID_FILE}"
    log "Running in foreground (PID $$)"
    exec ${COMMAND}
fi