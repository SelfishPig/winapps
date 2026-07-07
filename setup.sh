#!/usr/bin/env bash

set -o pipefail

readonly BOLD_TEXT="\033[1m"
readonly CLEAR_TEXT="\033[0m"
readonly COMMAND_TEXT="\033[0;37m"
readonly DONE_TEXT="\033[0;32m"
readonly ERROR_TEXT="\033[1;31m"
readonly FAIL_TEXT="\033[0;91m"
readonly INFO_TEXT="\033[0;33m"
readonly SUCCESS_TEXT="\033[1;42;37m"
readonly WARNING_TEXT="\033[1;33m"

readonly REPO_URL="https://github.com/SelfishPig/winapps.git"
readonly USER_SOURCE_PATH="${HOME}/.local/winapps"
readonly USER_BIN_PATH="${HOME}/.local/bin"
readonly USER_APP_PATH="${HOME}/.local/share/applications"
readonly USER_APPDATA_PATH="${HOME}/.local/share/winapps"
readonly CONFIG_DIR="${HOME}/.config/winapps"
readonly CONFIG_PATH="${CONFIG_DIR}/winapps.conf"
readonly COMPOSE_PATH="${CONFIG_DIR}/compose.yaml"

OPT_UNINSTALL=0
SOURCE_PATH="$USER_SOURCE_PATH"
BIN_PATH="$USER_BIN_PATH"
APP_PATH="$USER_APP_PATH"
APPDATA_PATH="$USER_APPDATA_PATH"

RDP_USER=""
RDP_PASS=""
CPU_CORES="4"
RAM_SIZE="4G"
DISK_SIZE="64G"
CREATED_COMPOSE=0

function waUsage() {
    echo "Usage:"
    echo -e "  ${COMMAND_TEXT}bash setup.sh${CLEAR_TEXT}             # Install WinApps for the current user"
    echo -e "  ${COMMAND_TEXT}bash setup.sh --user${CLEAR_TEXT}      # Install WinApps for the current user"
    echo -e "  ${COMMAND_TEXT}bash setup.sh --uninstall${CLEAR_TEXT} # Remove the current user's WinApps shortcuts and CLI links"
    echo -e "  ${COMMAND_TEXT}bash setup.sh --help${CLEAR_TEXT}      # Show this help message"
}

function waDie() {
    echo -e "${ERROR_TEXT}ERROR:${CLEAR_TEXT} ${1}"
    exit "${2:-1}"
}

function waCommandExists() {
    command -v "$1" &>/dev/null
}

function waFreeRDPAvailable() {
    local cmd=""
    local major=""

    for cmd in xfreerdp xfreerdp3 sdl-freerdp3 sdl3-freerdp sdl-freerdp; do
        if waCommandExists "$cmd"; then
            major=$("$cmd" --version 2>/dev/null | head -n 1 | grep -o -m 1 '\b[0-9]\S*' | head -n 1 | cut -d'.' -f1)
            if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 3)); then
                return 0
            fi
        fi
    done

    if waCommandExists flatpak && flatpak list --columns=application 2>/dev/null | grep -q "^com.freerdp.FreeRDP$"; then
        major=$(flatpak list --columns=application,version 2>/dev/null | grep "^com.freerdp.FreeRDP" | awk '{print $2}' | cut -d'.' -f1)
        if [[ "$major" =~ ^[0-9]+$ ]] && ((major >= 3)); then
            return 0
        fi
    fi

    return 1
}

function waCheckDependencies() {
    local missing=()

    waCommandExists git || missing+=("git")
    waCommandExists dialog || missing+=("dialog")
    waCommandExists notify-send || missing+=("libnotify / notify-send")
    waCommandExists nc || missing+=("netcat / nc")
    waCommandExists docker || missing+=("Docker Engine")
    waFreeRDPAvailable || missing+=("FreeRDP 3")

    if waCommandExists docker; then
        docker compose version &>/dev/null || missing+=("Docker Compose plugin")
        docker info &>/dev/null || missing+=("Docker daemon access for user '$(whoami)'")
    fi

    if [[ ! -e /dev/kvm ]]; then
        missing+=("/dev/kvm")
    elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        missing+=("read/write access to /dev/kvm")
    fi

    if ((${#missing[@]} > 0)); then
        echo -e "${ERROR_TEXT}ERROR:${CLEAR_TEXT} ${BOLD_TEXT}MISSING DEPENDENCIES.${CLEAR_TEXT}"
        echo -e "${INFO_TEXT}Install or enable the following before running setup again:${CLEAR_TEXT}"
        printf '  - %s\n' "${missing[@]}"
        echo
        echo "Common package names:"
        echo -e "  Debian/Ubuntu: ${COMMAND_TEXT}sudo apt install curl dialog freerdp3-x11 git libnotify-bin netcat-openbsd${CLEAR_TEXT}"
        echo -e "  Fedora/RHEL:   ${COMMAND_TEXT}sudo dnf install dialog freerdp git libnotify nmap-ncat${CLEAR_TEXT}"
        echo -e "  Arch Linux:    ${COMMAND_TEXT}sudo pacman -S dialog freerdp git libnotify openbsd-netcat${CLEAR_TEXT}"
        echo
        echo "Docker install instructions: https://docs.docker.com/engine/install/"
        exit 5
    fi
}

function waParseArguments() {
    local argument=""

    for argument in "$@"; do
        case "$argument" in
        "--user")
            ;;
        "--uninstall")
            OPT_UNINSTALL=1
            ;;
        "--help")
            waUsage
            exit 0
            ;;
        *)
            echo -e "${ERROR_TEXT}ERROR:${CLEAR_TEXT} ${BOLD_TEXT}INVALID ARGUMENT.${CLEAR_TEXT}"
            echo -e "${INFO_TEXT}Unsupported argument:${CLEAR_TEXT} ${COMMAND_TEXT}${argument}${CLEAR_TEXT}"
            echo
            waUsage
            exit 2
            ;;
        esac
    done
}

function waCloneOrUpdateSource() {
    echo -n "Preparing WinApps source at ${SOURCE_PATH}... "

    if [[ -d "$SOURCE_PATH/.git" ]]; then
        git -C "$SOURCE_PATH" remote set-url origin "$REPO_URL" &>/dev/null || true
        if ! git -C "$SOURCE_PATH" pull --ff-only &>/dev/null; then
            echo -e "${FAIL_TEXT}Failed!${CLEAR_TEXT}"
            waDie "Failed to update '${SOURCE_PATH}'. Resolve local git changes there, then rerun setup." 1
        fi
    elif [[ -e "$SOURCE_PATH" ]]; then
        echo -e "${FAIL_TEXT}Failed!${CLEAR_TEXT}"
        waDie "'${SOURCE_PATH}' already exists but is not a git checkout. Move it aside and rerun setup." 1
    else
        mkdir -p "$(dirname "$SOURCE_PATH")"
        if ! git clone --recurse-submodules --remote-submodules "$REPO_URL" "$SOURCE_PATH" &>/dev/null; then
            echo -e "${FAIL_TEXT}Failed!${CLEAR_TEXT}"
            waDie "Failed to clone '${REPO_URL}'." 1
        fi
    fi

    echo -e "${DONE_TEXT}Done!${CLEAR_TEXT}"
}

function waPromptValue() {
    local prompt="$1"
    local default_value="$2"
    local value=""

    read -r -p "${prompt} [${default_value}]: " value
    printf '%s' "${value:-$default_value}"
}

function waPromptRequired() {
    local prompt="$1"
    local default_value="${2:-}"
    local value=""

    while [[ -z "$value" ]]; do
        if [[ -n "$default_value" ]]; then
            read -r -p "${prompt} [${default_value}]: " value
            value="${value:-$default_value}"
        else
            read -r -p "${prompt}: " value
        fi
    done

    printf '%s' "$value"
}

function waPromptPassword() {
    local default_value="${1:-}"
    local value=""

    while [[ -z "$value" ]]; do
        if [[ -n "$default_value" ]]; then
            read -r -s -p "Windows password [existing value hidden]: " value
            echo
            value="${value:-$default_value}"
        else
            read -r -s -p "Windows password: " value
            echo
        fi
    done

    printf '%s' "$value"
}

function waNormalizeSize() {
    local value="$1"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        value="${value}G"
    fi

    printf '%s' "$value"
}

function waYamlQuote() {
    local value=""

    value=$(printf '%s' "$1" | sed "s/'/''/g")
    printf "'%s'" "$value"
}

function waShellQuote() {
    printf '%q' "$1"
}

function waLoadExistingConfigDefaults() {
    if [[ -f "$CONFIG_PATH" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_PATH"
    fi
}

function waPromptDockerConfig() {
    local default_user="${RDP_USER:-MyWindowsUser}"
    local default_pass="${RDP_PASS:-}"

    RDP_USER=$(waPromptRequired "Windows username" "$default_user")
    RDP_PASS=$(waPromptPassword "$default_pass")

    if [[ ! -f "$COMPOSE_PATH" ]]; then
        CPU_CORES=$(waPromptValue "CPU cores for the Windows container" "$CPU_CORES")
        RAM_SIZE=$(waNormalizeSize "$(waPromptValue "RAM for the Windows container" "$RAM_SIZE")")
        DISK_SIZE=$(waNormalizeSize "$(waPromptValue "Disk size for the Windows container" "$DISK_SIZE")")
    fi
}

function waRenderCompose() {
    local template_path="${SOURCE_PATH}/compose.yaml"
    local tmp_path=""
    local yaml_user=""
    local yaml_pass=""
    local yaml_cores=""
    local yaml_ram=""
    local yaml_disk=""

    [[ -f "$template_path" ]] || waDie "Missing compose template at '${template_path}'." 1

    yaml_user=$(waYamlQuote "$RDP_USER")
    yaml_pass=$(waYamlQuote "$RDP_PASS")
    yaml_cores=$(waYamlQuote "$CPU_CORES")
    yaml_ram=$(waYamlQuote "$RAM_SIZE")
    yaml_disk=$(waYamlQuote "$DISK_SIZE")
    tmp_path=$(mktemp "${CONFIG_DIR}/compose.yaml.XXXXXX") || waDie "Failed to create a temporary compose file." 1

    awk \
        -v user="$yaml_user" \
        -v pass="$yaml_pass" \
        -v cores="$yaml_cores" \
        -v ram="$yaml_ram" \
        -v disk="$yaml_disk" '
        /^[[:space:]]*USERNAME:/ { sub(/USERNAME:.*/, "USERNAME: " user); print; next }
        /^[[:space:]]*PASSWORD:/ { sub(/PASSWORD:.*/, "PASSWORD: " pass); print; next }
        /^[[:space:]]*CPU_CORES:/ { sub(/CPU_CORES:.*/, "CPU_CORES: " cores); print; next }
        /^[[:space:]]*RAM_SIZE:/ { sub(/RAM_SIZE:.*/, "RAM_SIZE: " ram); print; next }
        /^[[:space:]]*DISK_SIZE:/ { sub(/DISK_SIZE:.*/, "DISK_SIZE: " disk); print; next }
        /^[[:space:]]*-[[:space:]]+\.local\/winapps\/windows:\/storage/ {
            print "      - ${HOME}/.local/share/winapps/windows:/storage"
            next
        }
        { print }
    ' "$template_path" >"$tmp_path" || {
        rm -f "$tmp_path"
        waDie "Failed to render compose.yaml." 1
    }

    mv "$tmp_path" "$COMPOSE_PATH"
    CREATED_COMPOSE=1
}

function waRenderConfig() {
    local template_path="${SOURCE_PATH}/winapps.conf.template"
    local tmp_path=""
    local quoted_user=""
    local quoted_pass=""

    [[ -f "$template_path" ]] || waDie "Missing config template at '${template_path}'." 1

    quoted_user=$(waShellQuote "$RDP_USER")
    quoted_pass=$(waShellQuote "$RDP_PASS")
    tmp_path=$(mktemp "${CONFIG_DIR}/winapps.conf.XXXXXX") || waDie "Failed to create a temporary config file." 1

    awk -v user="$quoted_user" -v pass="$quoted_pass" '
        /^RDP_USER=/ { print "RDP_USER=" user; next }
        /^RDP_PASS=/ { print "RDP_PASS=" pass; next }
        /^WAFLAVOR=/ { print "WAFLAVOR=\"docker\""; next }
        /^RDP_IP=/ { print "RDP_IP=\"127.0.0.1\""; next }
        /^RDP_PORT=/ { print "RDP_PORT=\"3389\""; next }
        { print }
    ' "$template_path" >"$tmp_path" || {
        rm -f "$tmp_path"
        waDie "Failed to render winapps.conf." 1
    }

    chmod 600 "$tmp_path"
    mv "$tmp_path" "$CONFIG_PATH"
}

function waEnsureConfigFiles() {
    local need_prompts=0

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    mkdir -p "${HOME}/.local/share/winapps/windows"

    waLoadExistingConfigDefaults

    [[ -f "$COMPOSE_PATH" ]] || need_prompts=1
    [[ -f "$CONFIG_PATH" ]] || need_prompts=1

    if [[ "$need_prompts" -eq 1 ]]; then
        waPromptDockerConfig
    fi

    if [[ ! -f "$COMPOSE_PATH" ]]; then
        echo -n "Creating ${COMPOSE_PATH}... "
        waRenderCompose
        echo -e "${DONE_TEXT}Done!${CLEAR_TEXT}"
    else
        echo -e "${INFO_TEXT}Using existing Docker Compose file at ${COMMAND_TEXT}${COMPOSE_PATH}${CLEAR_TEXT}${INFO_TEXT}.${CLEAR_TEXT}"
    fi

    if [[ ! -f "$CONFIG_PATH" ]]; then
        echo -n "Creating ${CONFIG_PATH}... "
        waRenderConfig
        echo -e "${DONE_TEXT}Done!${CLEAR_TEXT}"
    else
        chmod 600 "$CONFIG_PATH"
        echo -e "${INFO_TEXT}Using existing WinApps config at ${COMMAND_TEXT}${CONFIG_PATH}${CLEAR_TEXT}${INFO_TEXT}.${CLEAR_TEXT}"
    fi
}

function waInstallCli() {
    echo -n "Installing WinApps commands... "

    mkdir -p "$BIN_PATH" "$APP_PATH" "${APPDATA_PATH}/icons"
    ln -sf "${SOURCE_PATH}/bin/winapps" "${BIN_PATH}/winapps"
    ln -sf "${SOURCE_PATH}/setup.sh" "${BIN_PATH}/winapps-setup"

    echo -e "${DONE_TEXT}Done!${CLEAR_TEXT}"
}

function waInstallWindowsLauncher() {
    local win_script="${BIN_PATH}/windows"
    local desktop_path="${APP_PATH}/windows.desktop"
    local icon_path="${APPDATA_PATH}/icons/windows.svg"

    echo -n "Creating Windows launcher... "

    mkdir -p "$BIN_PATH" "$APP_PATH" "${APPDATA_PATH}/icons"
    cp "${SOURCE_PATH}/install/windows.svg" "$icon_path"

    {
        echo "#!/usr/bin/env bash"
        echo "${BIN_PATH}/winapps windows \"\$@\""
    } >"$win_script"
    chmod a+x "$win_script"

    {
        echo "[Desktop Entry]"
        echo "Name=Windows"
        echo "Exec=${BIN_PATH}/winapps windows %F"
        echo "Terminal=false"
        echo "Type=Application"
        echo "Icon=${icon_path}"
        echo "StartupWMClass=Microsoft Windows"
        echo "Comment=Microsoft Windows RDP Session"
    } >"$desktop_path"

    echo -e "${DONE_TEXT}Done!${CLEAR_TEXT}"
}

function waEnsureOnPath() {
    if [[ ":$PATH:" != *":$BIN_PATH:"* ]]; then
        echo -e "${WARNING_TEXT}[WARNING]${CLEAR_TEXT} '${BIN_PATH}' is not on PATH."
        echo -e "${WARNING_TEXT}[WARNING]${CLEAR_TEXT} Add it to your shell profile, then restart your terminal:"
        echo -e "${COMMAND_TEXT}export PATH=\"${BIN_PATH}:\$PATH\"${CLEAR_TEXT}"
    fi
}

function waConfirm() {
    local prompt="$1"
    local answer=""

    read -r -p "${prompt} [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

function waMaybeStartContainer() {
    if [[ "$CREATED_COMPOSE" -ne 1 ]]; then
        return 0
    fi

    if waConfirm "Create and start the Windows Docker container now?"; then
        echo -e "${INFO_TEXT}Starting Windows with Docker Compose. This can take a while on first boot.${CLEAR_TEXT}"
        docker compose --file "$COMPOSE_PATH" up -d || waDie "Docker Compose failed to start the Windows container." 1
    fi
}

function waUninstall() {
    echo -e "${BOLD_TEXT}Removing the current user's WinApps installation.${CLEAR_TEXT}"

    rm -f "${BIN_PATH}/winapps" "${BIN_PATH}/winapps-setup" "${BIN_PATH}/windows"
    rm -f "${APP_PATH}/windows.desktop" "${APP_PATH}/ms-office-protocol-handler.desktop"

    if [[ -d "$BIN_PATH" ]]; then
        while IFS= read -r script_file; do
            rm -f "$script_file"
        done < <(grep -l -d skip "${BIN_PATH}/winapps" "${BIN_PATH}/"* 2>/dev/null || true)
    fi

    if [[ -d "$APP_PATH" ]]; then
        while IFS= read -r desktop_file; do
            rm -f "$desktop_file"
        done < <(grep -l -d skip "${BIN_PATH}/winapps" "${APP_PATH}/"* 2>/dev/null || true)
    fi

    echo -e "${INFO_TEXT}Configuration and source files were left in place:${CLEAR_TEXT}"
    echo -e "  ${COMMAND_TEXT}${CONFIG_DIR}${CLEAR_TEXT}"
    echo -e "  ${COMMAND_TEXT}${SOURCE_PATH}${CLEAR_TEXT}"
    echo -e "${SUCCESS_TEXT}UNINSTALLATION COMPLETE.${CLEAR_TEXT}"
}

function waInstall() {
    echo -e "${BOLD_TEXT}WinApps Docker setup${CLEAR_TEXT}"

    waCheckDependencies
    waCloneOrUpdateSource
    waEnsureConfigFiles
    waInstallCli
    waInstallWindowsLauncher
    waEnsureOnPath
    waMaybeStartContainer

    echo
    echo -e "${SUCCESS_TEXT}SETUP COMPLETE.${CLEAR_TEXT}"
    echo -e "If the container is running, finish Windows setup at ${COMMAND_TEXT}http://127.0.0.1:8006${CLEAR_TEXT}."
    echo -e "After installing Windows applications, run ${COMMAND_TEXT}winapps scan${CLEAR_TEXT} to add Linux shortcuts."
}

waParseArguments "$@"

if [[ "$OPT_UNINSTALL" -eq 1 ]]; then
    waUninstall
else
    waInstall
fi
