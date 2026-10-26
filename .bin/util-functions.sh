# Color codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

# Print banner
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌──────────────────────────────────────────────────┐"
    echo "│     Android Image Tools - by @ravindu644         │"
    echo "└──────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

# Detect OS type
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        # Pad with spaces so we can match whole words in ID_LIKE
        local ids=" ${ID} ${ID_LIKE} "
        if [[ "$ids" == *" debian "* ]] || [[ "$ids" == *" ubuntu "* ]]; then
            OS_TYPE="debian"
        elif [[ "$ids" == *" rhel "* ]] || [[ "$ids" == *" fedora "* ]]; then
            OS_TYPE="rhel"
        elif [[ "$ids" == *" arch "* ]] || [[ "$ids" == *" cachyos "* ]] || [[ "$ids" == *" manjaro "* ]] || [[ "$ids" == *" endeavouros "* ]]; then
            OS_TYPE="arch"
        else
            echo -e "${RED}Unsupported Operating System (ID=${ID}, ID_LIKE=${ID_LIKE}).${RESET}"
            exit 1
        fi
    else
        echo -e "${RED}Cannot detect OS.${RESET}"
        exit 1
    fi
}

check_dependencies() {
    local missing_pkgs=()
    local erofs_utils_missing=false
    local REQUIRED_PACKAGES=()
    local check_cmd=""

    if [ "$OS_TYPE" = "debian" ]; then
        REQUIRED_PACKAGES=("android-sdk-libsparse-utils" "build-essential" "automake" "autoconf" "libtool" "pkg-config" "git" "fuse3" "e2fsprogs" "pv" "liblz4-dev" "uuid-dev" "libfuse3-dev" "f2fs-tools" "fuse2fs" "attr" "zlib1g-dev" "rsync")
        check_cmd="dpkg -s"
    elif [ "$OS_TYPE" = "rhel" ]; then
        REQUIRED_PACKAGES=("android-tools" "gcc" "make" "automake" "autoconf" "libtool" "pkgconf" "git" "fuse3" "e2fsprogs" "pv" "lz4-devel" "libuuid-devel" "fuse3-devel" "f2fs-tools" "attr" "zlib-ng-compat-devel" "rsync")
        check_cmd="rpm -q"
    elif [ "$OS_TYPE" = "arch" ]; then
        REQUIRED_PACKAGES=("android-tools" "base-devel" "git" "fuse3" "e2fsprogs" "pv" "lz4" "util-linux" "f2fs-tools" "fuse2fs" "attr" "zlib" "rsync")
        check_cmd="pacman -Qi"
    fi

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! $check_cmd "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    # Command-based check: a package name can be installed while the tool the
    # script needs is still missing (renamed/split packages, partial installs).
    local -A CMD_PKG=()
    case "$OS_TYPE" in
        debian) CMD_PKG=([simg2img]=android-sdk-libsparse-utils [img2simg]=android-sdk-libsparse-utils [mke2fs]=e2fsprogs [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs [fuse2fs]=fuse2fs [mkfs.f2fs]=f2fs-tools [sload.f2fs]=f2fs-tools [pv]=pv [rsync]=rsync [setfattr]=attr [getfattr]=attr [fusermount3]=fuse3) ;;
        rhel)   CMD_PKG=([simg2img]=android-tools [img2simg]=android-tools [mke2fs]=e2fsprogs [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs [fuse2fs]=e2fsprogs [mkfs.f2fs]=f2fs-tools [sload.f2fs]=f2fs-tools [pv]=pv [rsync]=rsync [setfattr]=attr [getfattr]=attr [fusermount3]=fuse3) ;;
        arch)   CMD_PKG=([simg2img]=android-tools [img2simg]=android-tools [mke2fs]=e2fsprogs [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs [fuse2fs]=fuse2fs [mkfs.f2fs]=f2fs-tools [sload.f2fs]=f2fs-tools [pv]=pv [rsync]=rsync [setfattr]=attr [getfattr]=attr [fusermount3]=fuse3) ;;
    esac
    local missing_cmds=()
    local cmd
    for cmd in "${!CMD_PKG[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("${CMD_PKG[$cmd]}")
        fi
    done

    # Dedupe (a package can be flagged by both the package and command checks)
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        local -A _seen=()
        local _uniq=()
        local _p
        for _p in "${missing_pkgs[@]}"; do
            if [ -z "${_seen[$_p]}" ]; then
                _seen[$_p]=1
                _uniq+=("$_p")
            fi
        done
        missing_pkgs=("${_uniq[@]}")
    fi

    # Check for erofs-utils with FUSE support
    if ! command -v mkfs.erofs &>/dev/null || ! command -v erofsfuse &>/dev/null; then
        erofs_utils_missing=true
    fi

    if [ ${#missing_pkgs[@]} -eq 0 ] && [ "$erofs_utils_missing" = false ]; then
        return 0 # All dependencies are present, exit silently
    fi

    # If we reach here, some dependencies are missing.
    clear
    print_banner
    case "$OS_TYPE" in
        debian) echo -e "${RED}Debian Based host found...${RESET}" ;;
        rhel)   echo -e "${RED}Fedora Based host found...${RESET}" ;;
        arch)   echo -e "${RED}Arch Based host found...${RESET}" ;;
    esac
    echo -e "\n${RED}${BOLD}Warning: Missing required dependencies.${RESET}"

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}The following packages are missing:${RESET}"
        echo "  - ${missing_pkgs[*]}"
    fi

    if [ "$erofs_utils_missing" = true ]; then
        echo -e "\n${YELLOW}The 'erofs-utils' build tools are also missing.${RESET}"
    fi

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Required commands not found in PATH:${RESET}"
        echo "  - ${missing_cmds[*]}"
    fi

    read -rp "$(echo -e "\n${BLUE}Do you want to attempt automatic installation? (y/N): ${RESET}")" choice

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo -e "\n${YELLOW}Automatic installation declined.${RESET}"
        echo -e "Please install the dependencies manually and re-run the script."
        exit 1
    fi

    echo -e "\n${BLUE}Starting automatic installation...${RESET}"

    # ---- Distro packages ----
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        local unique_pkgs
        unique_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')

        case "$OS_TYPE" in
            debian)
                echo -e "\n${BLUE}Updating package lists...${RESET}"
                sudo apt update || { echo -e "${RED}apt update failed.${RESET}"; exit 1; }
                echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
                sudo apt install -y $unique_pkgs || { echo -e "${RED}Package installation failed.${RESET}"; exit 1; }
                ;;
            rhel)
                echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
                sudo dnf install -y $unique_pkgs || { echo -e "${RED}Package installation failed.${RESET}"; exit 1; }
                ;;
            arch)
                # Deliberately NOT -Syu: a dependency installer must not upgrade the
                # whole system (an unrelated conflict would abort the install).
                # Plain -S uses your current sync db; --needed skips installed pkgs.
                echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
                if ! sudo pacman -S --needed --noconfirm $unique_pkgs; then
                    echo -e "${RED}Package installation failed.${RESET}"
                    echo -e "${YELLOW}If pacman reported 404s or 'target not found', your sync db is stale:${RESET}"
                    echo -e "${YELLOW}run 'sudo pacman -Syu' yourself, then re-run this tool.${RESET}"
                    exit 1
                fi
                ;;
        esac
    fi

    # ---- erofs-utils ----
    if [ "$erofs_utils_missing" = true ]; then
        # On Arch, try the packaged version first (much faster than compiling)
        if [ "$OS_TYPE" = "arch" ]; then
            echo -e "\n${BLUE}Trying packaged 'erofs-utils' from the repos...${RESET}"
            sudo pacman -S --needed --noconfirm erofs-utils 2>/dev/null
        fi

        # Re-check; build from source only if still missing
        if ! command -v mkfs.erofs &>/dev/null || ! command -v erofsfuse &>/dev/null; then
            echo -e "\n${BLUE}Cloning and compiling 'erofs-utils'...${RESET}"
            local erofs_tmp_dir
            erofs_tmp_dir=$(mktemp -d)
            if ! git clone https://github.com/erofs/erofs-utils.git "$erofs_tmp_dir"; then
                echo -e "${RED}Failed to clone erofs-utils.${RESET}"
                rm -rf "$erofs_tmp_dir"
                exit 1
            fi

            # Subshell so a failure can't leave us in the wrong directory
            if ! (
                set -e
                cd "$erofs_tmp_dir"
                ./autogen.sh
                ./configure --enable-fuse
                make -j"$(nproc)"
                sudo make install
            ); then
                echo -e "${RED}Failed to build/install erofs-utils. See the error output above.${RESET}"
                rm -rf "$erofs_tmp_dir"
                exit 1
            fi
            rm -rf "$erofs_tmp_dir"
            sudo ldconfig 2>/dev/null
        fi

        if command -v mkfs.erofs &>/dev/null && command -v erofsfuse &>/dev/null; then
            echo -e "${GREEN}'erofs-utils' installed successfully.${RESET}"
        else
            echo -e "${RED}'erofs-utils' still not found in PATH (try /usr/local/bin).${RESET}"
            exit 1
        fi
    fi

    # Verify the commands really exist now instead of assuming
    local still_missing=()
    for cmd in "${missing_cmds[@]}"; do
        command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
    done
    if [ ${#still_missing[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}Still not found after install: ${still_missing[*]}${RESET}"
        echo -e "${YELLOW}Your distro may ship these in a different package; install them manually.${RESET}"
    fi

    echo -e "\n${GREEN}${BOLD}[✓] All dependencies should now be installed.${RESET}"
    read -rp "Press Enter to continue..."
}