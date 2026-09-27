#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Генерация пароля для инстанса. Раньше в конфиги подставлялась строка
# "hackme" — дефолтный пароль Icecast, из-за которого любой желающий мог
# подключиться источником или зайти в админку.
function gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

function show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --install-core            Install dependencies and prepare environment"
    echo "  --create-instance [name]  Create a new radio instance"
}

function install_core() {
    echo "Installing core dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y mpd icecast2 mpc iproute2

    echo "Disabling default services..."
    systemctl stop mpd.socket mpd.service icecast2.service || true
    systemctl disable mpd.socket mpd.service icecast2.service || true
    echo "Core installation complete."
}

function get_free_port() {
    local port=$1
    while true; do
        local in_use=0
        if ss -tln | grep -q ":$port "; then
            in_use=1
        elif [ -d /etc/radio-instances ] && grep -qRE "(port[[:space:]]+\"$port\"|<port>$port</port>)" /etc/radio-instances/ 2>/dev/null; then
            in_use=1
        fi

        if [ "$in_use" -eq 1 ]; then
            port=$((port + 1))
        else
            echo "$port"
            return
        fi
    done
}

function create_instance() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Error: Instance name is required." >&2
        exit 1
    fi

    # Имя попадает в имена пользователя, systemd-юнитов и в пути
    # (/etc/radio-instances/$name, /var/log/$name). Без проверки имя вида
    # "../../etc" или с пробелами ломало бы пути и юниты.
    if ! [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
        echo "Error: Invalid instance name. Use lowercase letters, digits, '_' and '-' (max 31 chars, must not start with a digit)." >&2
        exit 1
    fi

    if id -u "$name" >/dev/null 2>&1; then
        echo "Error: User $name already exists." >&2
        exit 1
    fi

    echo "Creating instance: $name"

    # User creation
    useradd -r -s /usr/sbin/nologin "$name"

    # Port allocation
    local mpd_port=$(get_free_port 6600)
    local ice_port=$(get_free_port 8000)

    if [ "$mpd_port" -eq "$ice_port" ]; then
        ice_port=$(get_free_port $((ice_port + 1)))
    fi

    echo "Allocated MPD port: $mpd_port"
    echo "Allocated Icecast port: $ice_port"

    # Директории
    local conf_dir="/etc/radio-instances/$name"
    local music_dir="/var/lib/radio-instances/$name/music"
    local playlist_dir="/var/lib/radio-instances/$name/playlists"
    local log_dir="/var/log/$name"
    local run_dir="/run/$name"
    local db_dir="/var/lib/radio-instances/$name/db"

    mkdir -p "$conf_dir"
    mkdir -p "$music_dir"
    mkdir -p "$playlist_dir"
    mkdir -p "$db_dir"
    # Страховка на случай, если LogsDirectory/RuntimeDirectory не сработают:
    # оба конфига ссылаются на эти каталоги при старте.
    mkdir -p "$log_dir"
    mkdir -p "$run_dir"

    # Права доступа
    chown -R "$name:$name" "$music_dir" "$playlist_dir" "$db_dir"
    chmod 750 "$music_dir" "$playlist_dir" "$db_dir"
    chown "$name:$name" "$log_dir"
    chmod 750 "$log_dir"
    chown "$name:$name" "$run_dir"
    chmod 755 "$run_dir"
    chown root:"$name" "$conf_dir"
    chmod 750 "$conf_dir"

    # Пароли для этого инстанса: source/relay/admin в Icecast и source в MPD.
    local source_pass admin_pass relay_pass
    source_pass="$(gen_secret)"
    admin_pass="$(gen_secret)"
    relay_pass="$(gen_secret)"

    # Generate MPD config
    local mpd_conf="$conf_dir/mpd.conf"
    cat > "$mpd_conf" <<EOF
music_directory    "$music_dir"
playlist_directory "$playlist_dir"
log_file           "$log_dir/mpd.log"
pid_file           "$run_dir/mpd.pid"
state_file         "$db_dir/state"

database {
    plugin "simple"
    path "$db_dir/database"
    cache_directory "$db_dir/cache"
}

user               "$name"
# Только loopback: MPD не имеет пароля в этой конфигурации, а bind на
# 0.0.0.0 открывал управление плеером (порт 6600) всему интернету.
bind_to_address    "127.0.0.1"
port               "$mpd_port"

auto_update        "yes"

audio_output {
    type        "shout"
    encoder     "vorbis"
    name        "$name stream"
    host        "127.0.0.1"
    port        "$ice_port"
    mount       "/stream"
    password    "$source_pass"
    bitrate     "128"
    format      "44100:16:2"
}
EOF
    chown root:"$name" "$mpd_conf"
    chmod 640 "$mpd_conf"

    # Generate Icecast config
    local ice_conf="$conf_dir/icecast.xml"
    cat > "$ice_conf" <<EOF
<icecast>
    <location>Earth</location>
    <admin>icemaster@localhost</admin>

    <limits>
        <clients>100</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>65535</burst-size>
    </limits>

    <authentication>
        <source-password>$source_pass</source-password>
        <relay-password>$relay_pass</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>$admin_pass</admin-password>
    </authentication>

    <hostname>localhost</hostname>

    <listen-socket>
        <port>$ice_port</port>
    </listen-socket>

    <paths>
        <basedir>/usr/share/icecast2</basedir>
        <logdir>$log_dir</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
        <pidfile>$run_dir/icecast.pid</pidfile>
        <alias source="/" destination="/status.xsl"/>
    </paths>

    <logging>
        <accesslog>icecast_access.log</accesslog>
        <errorlog>icecast_error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
    </logging>
</icecast>
EOF
    chown root:"$name" "$ice_conf"
    chmod 640 "$ice_conf"

    # Systemd units
    cat > "/etc/systemd/system/mpd-$name.service" <<EOF
[Unit]
Description=Music Player Daemon for $name
After=network.target sound.target icecast-$name.service

[Service]
Type=notify
RuntimeDirectory=$name
LogsDirectory=$name
ExecStart=/usr/bin/mpd --no-daemon $mpd_conf
User=$name
Group=$name
LimitCORE=infinity
LimitRTPRIO=50
LimitRTTIME=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > "/etc/systemd/system/icecast-$name.service" <<EOF
[Unit]
Description=Icecast2 streaming media server for $name
After=network.target

[Service]
Type=simple
RuntimeDirectory=$name
LogsDirectory=$name
ExecStart=/usr/bin/icecast2 -c $ice_conf
User=$name
Group=$name

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "icecast-$name.service"
    systemctl enable "mpd-$name.service"
    systemctl start "icecast-$name.service"
    systemctl start "mpd-$name.service"

    # Пароли сохранены, потому что после генерации узнать их больше негде.
    cat > "$conf_dir/credentials.txt" <<EOF
instance=$name
mpd_port=$mpd_port
icecast_port=$ice_port
icecast_source_password=$source_pass
icecast_relay_password=$relay_pass
icecast_admin_user=admin
icecast_admin_password=$admin_pass
EOF
    chown root:root "$conf_dir/credentials.txt"
    chmod 600 "$conf_dir/credentials.txt"

    echo "Instance $name created and started."
    echo "MPD Port (только localhost): $mpd_port"
    echo "Icecast Port: $ice_port"
    echo "Icecast source password: $source_pass"
    echo "Icecast admin login:     admin / $admin_pass"
    echo "Учётные данные сохранены в $conf_dir/credentials.txt"
}

if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

case "$1" in
    --install-core)
        install_core
        ;;
    --create-instance)
        create_instance "${2:-}"
        ;;
    *)
        show_help
        exit 1
        ;;
esac
