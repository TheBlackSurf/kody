#!/bin/bash

# Ten skrypt jest przeznaczony do załadowania przez /etc/profile lub /etc/profile.d/*.sh
# Definiuje funkcję wywoływaną przez PROMPT_COMMAND.

LXC_LOGGER_PROXMOX_IP="__PROXMOX_IP_PLACEHOLDER__"
LXC_LOGGER_SYSLOG_PORT="__SYSLOG_PORT_PLACEHOLDER__"
LXC_LOGGER_FACILITY="local1.notice"
LXC_LOGGER_TAG="lxc-cmd" # Tag dla logów w syslogu

__lxc_log_command_action() {
    local last_cmd
    # Pobierz ostatnią komendę; 'fc -ln -1' jest bardziej niezawodne, ale 'history 1 | sed ...' jest bardziej przenośne
    last_cmd=$(history 1 | sed 's/^[ ]*[0-9]\+[ ]*//')

    # Sprawdź, czy komenda nie jest pusta i czy nie jest to samo wywołanie PROMPT_COMMAND
    if [ -n "$last_cmd" ] && [ "$last_cmd" != "$PROMPT_COMMAND" ]; then
        if command -v logger >/dev/null; then
            logger -n "${LXC_LOGGER_PROXMOX_IP}" \
                   -P "${LXC_LOGGER_SYSLOG_PORT}" \
                   -p "${LXC_LOGGER_FACILITY}" \
                   -t "${LXC_LOGGER_TAG}" \
                   -- "$(whoami)@$(hostname): ${last_cmd}"
        else
            # echo "$(date): Logger not found. Cmd: $(whoami)@$(hostname): ${last_cmd}" >> /tmp/lxc_cmd_log_fallback.txt
            : 
        fi
    fi
    return 0 
}

# Upewnij się, że funkcja nie jest redefiniowana
if ! declare -f __lxc_log_command_action > /dev/null; then
    # Definicja jest już powyżej
    :
fi