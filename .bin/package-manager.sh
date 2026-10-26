#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/.bin/util-functions.sh" || {
    echo "Error: util-functions.sh not found" >&2
    exit 1
}

PM_PROJECT=""
PM_RESTORE_DIR=""
PM_SELECTED=()
PM_APK_PATHS=()
PM_APK_PACKAGES=()
PM_APK_LABELS=()
PM_APK_VERSIONS=()
PM_APK_SIZES=()
PM_CHOICE=0

pm_menu() {
    local header="$1"
    shift
    local -a options=("$@")
    local current=0
    local is_first_iteration=true
    local terminal_lines terminal_columns header_newlines menu_start visible_rows visible_count
    terminal_lines="$(tput lines 2>/dev/null || printf '24')"
    terminal_columns="$(tput cols 2>/dev/null || printf '80')"
    [[ "$terminal_lines" =~ ^[0-9]+$ ]] || terminal_lines=24
    [[ "$terminal_columns" =~ ^[0-9]+$ ]] || terminal_columns=80
    (( terminal_columns < 8 )) && terminal_columns=80
    header_newlines="${header//[^$'\n']/}"
    menu_start=$((8 + ${#header_newlines}))
    visible_rows=$((terminal_lines - menu_start - 2))
    (( visible_rows < 1 )) && visible_rows=1
    visible_count=${#options[@]}
    (( visible_count > visible_rows )) && visible_count=$visible_rows

    tput civis 2>/dev/null || true
    clear 2>/dev/null || printf '\033[2J\033[H'
    print_banner
    printf '\n'
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%.*s\n' "$((terminal_columns - 1))" "$line"
    done <<< "$header"
    printf '\n'

    while true; do
        if [ "$is_first_iteration" = false ]; then
            tput cuu "$visible_count" 2>/dev/null || true
        fi

        local first_visible=$((current - visible_count + 1))
        (( first_visible < 0 )) && first_visible=0
        local last_visible=$((first_visible + visible_count - 1))
        (( last_visible >= ${#options[@]} )) && last_visible=$((${#options[@]} - 1))

        for ((i = first_visible; i <= last_visible; i++)); do
            tput el 2>/dev/null || true
            local option_text="${options[$i]}"
            option_text="${option_text//$'\n'/ }"
            option_text="${option_text//$'\r'/ }"
            option_text="${option_text//$'\t'/ }"
            if (( ${#option_text} > terminal_columns - 5 )); then
                printf -v option_text '%.*s' "$((terminal_columns - 5))" "$option_text"
            fi
            if [ "$i" -eq "$current" ]; then
                printf '  %b▶ %s%b\n' "$GREEN" "$option_text" "$RESET"
            else
                printf '    %s\n' "$option_text"
            fi
        done

        is_first_iteration=false
        IFS= read -rsn1 key || key=""
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -rsn2 key || key=""
            case "$key" in
                '[A') current=$(( (current - 1 + ${#options[@]}) % ${#options[@]} )) ;;
                '[B') current=$(( (current + 1) % ${#options[@]} )) ;;
            esac
        elif [[ -z "$key" ]]; then
            break
        fi
    done

    tput cnorm 2>/dev/null || true
    PM_CHOICE=$current
}

pm_pause() {
    read -rp $'\nPress Enter to continue...'
}

pm_is_selected() {
    local candidate
    for candidate in "${PM_SELECTED[@]}"; do
        [ "$candidate" = "$1" ] && return 0
    done
    return 1
}

pm_toggle_selected() {
    local path="$1"
    local index
    for index in "${!PM_SELECTED[@]}"; do
        if [ "${PM_SELECTED[$index]}" = "$path" ]; then
            unset 'PM_SELECTED[index]'
            PM_SELECTED=("${PM_SELECTED[@]}")
            return
        fi
    done
    PM_SELECTED+=("$path")
}

pm_read_metadata() {
    local apk="$1"
    local fallback="${apk##*/}"
    fallback="${fallback%.*}"
    local badging=""
    local package="$fallback"
    local label="$fallback"
    local version="Unknown"

    if command -v aapt >/dev/null 2>&1; then
        badging="$(aapt dump badging "$apk" 2>/dev/null || true)"
        local value
        value="$(printf '%s\n' "$badging" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1)"
        [ -n "$value" ] && package="$value"
        value="$(printf '%s\n' "$badging" | sed -n "s/^application-label:'\(.*\)'$/\1/p" | head -n 1)"
        [ -n "$value" ] && label="$value"
        value="$(printf '%s\n' "$badging" | sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p" | head -n 1)"
        [ -n "$value" ] && version="$value"
    fi

    PM_APK_PACKAGES+=("$package")
    PM_APK_LABELS+=("$label")
    PM_APK_VERSIONS+=("$version")
    PM_APK_SIZES+=("$(stat -c '%s' "$apk" 2>/dev/null || printf '0')")
}

pm_scan() {
    PM_APK_PATHS=()
    PM_APK_PACKAGES=()
    PM_APK_LABELS=()
    PM_APK_VERSIONS=()
    PM_APK_SIZES=()

    while IFS= read -r -d '' apk; do
        PM_APK_PATHS+=("$apk")
        pm_read_metadata "$apk"
    done < <(find "$PM_PROJECT" -path "$PM_RESTORE_DIR" -prune -o -type f -iname '*.apk' -print0)

    local -a selected_paths=()
    local selected_path
    for selected_path in "${PM_SELECTED[@]}"; do
        [ -f "$selected_path" ] && selected_paths+=("$selected_path")
    done
    PM_SELECTED=("${selected_paths[@]}")
}

pm_choose_project() {
    local -a projects=()
    local base directory
    for base in "$SCRIPT_DIR/EXTRACTED_IMAGES" "$SCRIPT_DIR/SUPER_TOOLS"; do
        [ -d "$base" ] || continue
        while IFS= read -r -d '' directory; do
            projects+=("$directory")
        done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    done

    if [ "${#projects[@]}" -eq 0 ]; then
        clear 2>/dev/null || true
        print_banner
        echo -e "${YELLOW}No extracted image or super-image projects were found.${RESET}"
        pm_pause
        return 1
    fi

    local -a options=()
    for directory in "${projects[@]}"; do
        options+=("${directory#"$SCRIPT_DIR"/}")
    done
    options+=("Back")
    pm_menu "Select a project to scan for APK files:" "${options[@]}"
    [ "$PM_CHOICE" -eq "$((${#options[@]} - 1))" ] && return 1

    PM_PROJECT="$(realpath -e -- "${projects[$PM_CHOICE]}")" || {
        echo -e "${RED}Could not resolve the selected project path.${RESET}"
        pm_pause
        return 1
    }
    PM_RESTORE_DIR="$PM_PROJECT/.apk_manager_restore"
    PM_SELECTED=()
    return 0
}

pm_browse_apks() {
    if [ "${#PM_APK_PATHS[@]}" -eq 0 ]; then
        clear 2>/dev/null || true
        print_banner
        echo -e "${YELLOW}No APK files found in this project.${RESET}"
        pm_pause
        return
    fi

    while true; do
        local -a options=()
        local index marker
        for index in "${!PM_APK_PATHS[@]}"; do
            marker='[ ]'
            pm_is_selected "${PM_APK_PATHS[$index]}" && marker='[x]'
            options+=("$marker ${PM_APK_LABELS[$index]} -- ${PM_APK_PACKAGES[$index]}")
        done
        options+=("Back")
        pm_menu "Select an APK to view details or toggle its selection:" "${options[@]}"
        [ "$PM_CHOICE" -eq "$((${#options[@]} - 1))" ] && return

        index=$PM_CHOICE
        local details
        printf -v details 'Name:       %s\nPackage:    %s\nVersion:    %s\nSize:       %s bytes\nPath:       %s\n' \
            "${PM_APK_LABELS[$index]}" "${PM_APK_PACKAGES[$index]}" \
            "${PM_APK_VERSIONS[$index]}" "${PM_APK_SIZES[$index]}" \
            "${PM_APK_PATHS[$index]#"$PM_PROJECT"/}"
        local -a detail_options=("Toggle selection" "Back")
        pm_menu "APK details"$'\n'"$details" "${detail_options[@]}"
        if [ "$PM_CHOICE" -eq 0 ]; then
            pm_toggle_selected "${PM_APK_PATHS[$index]}"
        fi
    done
}

pm_import_list() {
    local filename
    read -rp "Path to package list: " filename
    [ -n "$filename" ] || return
    if [ ! -f "$filename" ] || [ ! -r "$filename" ]; then
        echo -e "${RED}Cannot read package list: $filename${RESET}"
        pm_pause
        return
    fi

    local -a entries=()
    local line entry index matched=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* || "$line" == //* ]] && continue
        entries+=("${line,,}")
    done < "$filename"

    for index in "${!PM_APK_PATHS[@]}"; do
        local package="${PM_APK_PACKAGES[$index],,}"
        local apk_name="${PM_APK_PATHS[$index]##*/}"
        apk_name="${apk_name%.*}"
        for entry in "${entries[@]}"; do
            if [ "$entry" = "$package" ] || [ "$entry" = "${apk_name,,}" ]; then
                if ! pm_is_selected "${PM_APK_PATHS[$index]}"; then
                    PM_SELECTED+=("${PM_APK_PATHS[$index]}")
                fi
                matched=$((matched + 1))
                break
            fi
        done
    done

    if [ "$matched" -eq 0 ]; then
        echo -e "${YELLOW}No APKs matched the imported list.${RESET}"
    else
        echo -e "${GREEN}Selected $matched matching APK(s).${RESET}"
    fi
    pm_pause
}

pm_save_list() {
    if [ "${#PM_SELECTED[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Select at least one APK first.${RESET}"
        pm_pause
        return
    fi
    local default_path="$PM_PROJECT/selected-packages.txt"
    local filename
    read -rp "Save package list to [$default_path]: " filename
    filename="${filename:-$default_path}"
    if [ -e "$filename" ]; then
        read -rp "File exists. Overwrite it? (y/N): " confirmation
        [[ "$confirmation" =~ ^[Yy]$ ]] || return
    fi
    if ! : > "$filename"; then
        echo -e "${RED}Could not write package list: $filename${RESET}"
        pm_pause
        return
    fi

    local path index
    for path in "${PM_SELECTED[@]}"; do
        for index in "${!PM_APK_PATHS[@]}"; do
            if [ "${PM_APK_PATHS[$index]}" = "$path" ]; then
                printf '%s\n' "${PM_APK_PACKAGES[$index]}" >> "$filename"
                break
            fi
        done
    done
    echo -e "${GREEN}Saved ${#PM_SELECTED[@]} package(s) to $filename${RESET}"
    pm_pause
}

pm_remove_selected() {
    if [ "${#PM_SELECTED[@]}" -eq 0 ]; then
        echo -e "${YELLOW}No APKs are selected.${RESET}"
        pm_pause
        return
    fi
    printf 'Move %s selected APK(s) to the restore folder?\n' "${#PM_SELECTED[@]}"
    printf 'Restore location: %s\n' "${PM_RESTORE_DIR#"$SCRIPT_DIR"/}"
    read -rp "Type 'yes' to continue: " confirmation
    [ "$confirmation" = "yes" ] || return

    local path original_path relative destination errors=0
    local -a failed_paths=()
    for path in "${PM_SELECTED[@]}"; do
        original_path="$path"
        path="$(realpath -e -- "$original_path")" || {
            echo -e "${RED}APK no longer exists: $original_path${RESET}"
            errors=$((errors + 1))
            failed_paths+=("$original_path")
            continue
        }
        if [[ "$path" != "$PM_PROJECT/"* ]]; then
            echo -e "${RED}Refusing to move APK outside the selected project: $path${RESET}"
            errors=$((errors + 1))
            failed_paths+=("$original_path")
            continue
        fi
        relative="${path#"$PM_PROJECT"/}"
        destination="$PM_RESTORE_DIR/$relative"
        if [ -e "$destination" ]; then
            echo -e "${RED}Restore destination already exists: $destination${RESET}"
            errors=$((errors + 1))
            failed_paths+=("$original_path")
            continue
        fi
        if ! mkdir -p -- "$(dirname "$destination")" || ! mv -- "$path" "$destination"; then
            echo -e "${RED}Could not move APK: $path${RESET}"
            errors=$((errors + 1))
            failed_paths+=("$original_path")
        fi
    done

    PM_SELECTED=("${failed_paths[@]}")
    pm_scan
    if [ "$errors" -eq 0 ]; then
        echo -e "${GREEN}Selected APKs moved to the restore folder.${RESET}"
    else
        echo -e "${YELLOW}Move completed with $errors error(s); see messages above.${RESET}"
    fi
    pm_pause
}

pm_restore_apks() {
    if [ ! -d "$PM_RESTORE_DIR" ]; then
        echo -e "${YELLOW}There are no APKs to restore.${RESET}"
        pm_pause
        return
    fi

    local -a restore_paths=()
    local path
    while IFS= read -r -d '' path; do
        restore_paths+=("$path")
    done < <(find "$PM_RESTORE_DIR" -type f -iname '*.apk' -print0)
    if [ "${#restore_paths[@]}" -eq 0 ]; then
        echo -e "${YELLOW}There are no APKs to restore.${RESET}"
        pm_pause
        return
    fi

    printf 'Restore %s APK(s) to their original locations?\n' "${#restore_paths[@]}"
    read -rp "Type 'yes' to continue: " confirmation
    [ "$confirmation" = "yes" ] || return

    local relative destination errors=0
    for path in "${restore_paths[@]}"; do
        relative="${path#"$PM_RESTORE_DIR"/}"
        destination="$PM_PROJECT/$relative"
        if [ -e "$destination" ]; then
            echo -e "${RED}Restore destination already exists: $destination${RESET}"
            errors=$((errors + 1))
            continue
        fi
        if ! mkdir -p -- "$(dirname "$destination")" || ! mv -- "$path" "$destination"; then
            echo -e "${RED}Could not restore APK: $destination${RESET}"
            errors=$((errors + 1))
        fi
    done

    pm_scan
    if [ "$errors" -eq 0 ]; then
        echo -e "${GREEN}APK restoration completed.${RESET}"
    else
        echo -e "${YELLOW}Restore completed with $errors error(s); see messages above.${RESET}"
    fi
    pm_pause
}

pm_manage_project() {
    pm_scan
    while true; do
        local restore_count=0
        if [ -d "$PM_RESTORE_DIR" ]; then
            restore_count="$(find "$PM_RESTORE_DIR" -type f -iname '*.apk' -print | wc -l)"
        fi
        local -a options=(
            "Browse and select APKs"
            "Import package list"
            "Save selection list"
            "Remove selected APKs"
            "Restore APKs ($restore_count)"
            "Rescan project"
            "Change project"
            "Back"
        )
        local header
        printf -v header 'APK Package Manager\nProject: %s\nAPKs found: %s | Selected: %s\nChoose an action:' \
            "${PM_PROJECT#"$SCRIPT_DIR"/}" "${#PM_APK_PATHS[@]}" "${#PM_SELECTED[@]}"
        pm_menu "$header" "${options[@]}"
        case "$PM_CHOICE" in
            0) pm_browse_apks ;;
            1) pm_import_list ;;
            2) pm_save_list ;;
            3) pm_remove_selected ;;
            4) pm_restore_apks ;;
            5) pm_scan ;;
            6) return 2 ;;
            7) return 0 ;;
        esac
    done
}

pm_run() {
    while true; do
        pm_choose_project || return 0
        pm_manage_project
        [ "$?" -eq 2 ] || return 0
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    pm_run
fi
