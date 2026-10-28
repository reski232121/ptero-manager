#!/bin/bash

function backup_db_only() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    if [ -z "$DB_PASS" ]; then
        fail "Password database tidak boleh kosong."
        pause
        return 1
    fi
    local dest
    dest="$BACKUP_ROOT/db_only_$(date +%F_%H-%M-%S).sql"
    mkdir -p "$BACKUP_ROOT"
    echo -e "${BLUE}[*] Backup database saja...${NC}"
    if mysqldump_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" > "$dest"; then
        local size
        size=$(du -sh "$dest" | awk '{print $1}')
        log_msg "Backup DB only sukses: $dest ($size)"
        notify_detail "BACKUP DB" "Backup database selesai: $(basename "$dest") ($size)"
        echo -e "${GREEN}Backup database selesai: $dest ($size)${NC}"
    else
        rm -f "$dest"
        fail "Backup database gagal."
    fi
    pause
}

function backup_system() {
    require_root || return 1
    read -r -s -p "Password database user $DB_USER: " DB_PASS
    echo
    backup_system_with_password "$DB_PASS" "yes"
}

function backup_system_with_password() {
    local backup_password="$1"
    local interactive="${2:-no}"

    if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y zip unzip >/dev/null 2>&1 || true
    fi

    acquire_lock || { [ "$interactive" = "yes" ] && pause; return 1; }
    trap 'release_lock' EXIT

    local dest_dir dest start_ts end_ts duration
    dest_dir="ptero_$(date +%F_%H-%M-%S)"
    dest="$BACKUP_ROOT/$dest_dir"
    mkdir -p "$dest"
    start_ts=$(date +%s)

    log_msg "Backup dimulai: $dest"
    qprint "${BLUE}[*] Memulai backup database, panel, Wings, dan volume...${NC}"

    if mysqldump_secure "$DB_USER" "$backup_password" -h 127.0.0.1 "$DB_NAME" \
            > "$dest/panel_db.sql"; then

        echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$dest/backup.meta"

        (cd /var/www && zip -r "$dest/panel_files.zip" pterodactyl) 2>/dev/null || true
        [ -d "$WINGS_DIR" ] && cp -a "$WINGS_DIR" "$dest/wings_config"
        if [ -d /var/lib/pterodactyl/volumes ]; then
            (cd /var/lib && zip -r "$dest/server_volumes.zip" pterodactyl/volumes) 2>/dev/null || true
        fi

        local total_size
        total_size=$(du -sh "$dest" | awk '{print $1}')

        local failed=0
        for f in panel_db.sql panel_files.zip server_volumes.zip; do
            if [ -f "$dest/$f" ] && [ ! -s "$dest/$f" ]; then
                qprint "${RED}PERINGATAN: $f kosong!${NC}"
                log_msg "PERINGATAN: backup file $f kosong"
                failed=1
            fi
        done

        local rclone_status="skip"
        if command -v rclone >/dev/null 2>&1 && [ -f /root/.ptero_rclone ]; then
            local r_info
            r_info=$(cat /root/.ptero_rclone)
            qprint "${BLUE}[*] Upload backup ke cloud...${NC}"
            if rclone copy "$dest" "$r_info/$dest_dir" --progress 2>&1; then
                rclone_status="ok"
                notify_detail "BACKUP CLOUD" "Backup cloud OK: $dest_dir ($total_size)"
            else
                rclone_status="fail"
                qprint "${RED}Upload cloud GAGAL.${NC}"
                log_msg "Upload cloud gagal untuk $dest_dir"
                notify_detail "BACKUP CLOUD GAGAL" "Upload cloud gagal: $dest_dir"
            fi
        fi

        cleanup_old_backups
        end_ts=$(date +%s)
        duration=$((end_ts - start_ts))
        log_msg "Backup sukses: $dest ($total_size, ${duration}s, cloud=$rclone_status)"

        if [ "$failed" -eq 0 ]; then
            notify_detail "BACKUP OK" "Backup lokal selesai: $dest_dir ($total_size, ${duration}s)"
            qprint "${GREEN}Backup selesai di $dest ($total_size, ${duration}s)${NC}"
        else
            notify_detail "BACKUP WARN" "Backup selesai DENGAN PERINGATAN: $dest_dir"
            qprint "${YELLOW}Backup selesai tapi ada file yang kosong. Cek di $dest${NC}"
        fi
    else
        rm -rf "$dest"
        log_msg "Backup gagal"
        notify_detail "BACKUP GAGAL" "Backup database gagal! Periksa password."
        fail "Backup database gagal. Periksa password database."
    fi

    release_lock
    trap - EXIT

    if [ "$interactive" = "yes" ]; then
        pause
    fi
}

function preview_backup() {
    local b="$1"
    echo -e "${BLUE}=== Preview Backup ===${NC}"
    echo -e "Path     : $b"
    echo -e "Tanggal  : $(stat -c %y "$b" 2>/dev/null | cut -d. -f1)"
    echo -e "Total    : $(du -sh "$b" 2>/dev/null | awk '{print $1}')"
    echo
    if [ -f "$b/panel_db.sql" ]; then
        echo -e "  ${GREEN}[v]${NC} Database  : $(du -sh "$b/panel_db.sql" | awk '{print $1}')"
    fi
    if [ -f "$b/panel_files.zip" ]; then
        echo -e "  ${GREEN}[v]${NC} Panel     : $(du -sh "$b/panel_files.zip" | awk '{print $1}')"
    fi
    if [ -d "$b/wings_config" ]; then
        echo -e "  ${GREEN}[v]${NC} Wings cfg : $(du -sh "$b/wings_config" | awk '{print $1}')"
    fi
    if [ -f "$b/server_volumes.zip" ]; then
        echo -e "  ${GREEN}[v]${NC} Volume    : $(du -sh "$b/server_volumes.zip" | awk '{print $1}')"
    fi
    if [ -f "$b/backup.meta" ]; then
        local _domain
        _domain=$(grep -oP '^PANEL_DOMAIN=\K.*' "$b/backup.meta" 2>/dev/null || echo "?")
        echo -e "  ${GREEN}[v]${NC} Domain    : $_domain"
    fi
    echo
}

function restore_system() {
    require_root || return 1
    if ! command -v unzip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y unzip >/dev/null 2>&1 || true
    fi
    header
    echo -e "${YELLOW}PERINGATAN: Restore akan menimpa data panel sesuai komponen yang dipilih.${NC}"

    local BACKUP_PATH="${1:-}"
    if [ -z "$BACKUP_PATH" ]; then
        mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
        if [ "${#BACKUPS[@]}" -eq 0 ]; then
            fail "Tidak ada backup tersedia di $BACKUP_ROOT."
            pause
            return 1
        fi
        echo -e "${BLUE}Daftar backup tersedia:${NC}"
        BACKUP_PATH=$(pick_from_list "Pilih nomor backup:" "${BACKUPS[@]}") || {
            fail "Pilihan tidak valid."; pause; return 1
        }
    fi
    echo
    preview_backup "$BACKUP_PATH"

    echo -e "${CYAN}Komponen yang ingin di-restore:${NC}"
    echo "1) Lengkap (database + panel + wings + volume)"
    echo "2) Database saja"
    echo "3) Panel files saja"
    echo "4) Wings config saja"
    echo "5) Server volumes saja"
    echo "0) Batal"
    read -r -p "Pilih [0-5]: " RMODE
    [ "$RMODE" = "0" ] && { echo "Dibatalkan."; pause; return 0; }
    if ! echo "$RMODE" | grep -Eq '^[1-5]$'; then
        fail "Pilihan tidak valid."; pause; return 1
    fi

    confirm_action "Lanjut restore mode $RMODE dari: $BACKUP_PATH ?" \
        || { echo "Dibatalkan."; pause; return 1; }

    if [ ! -d "$BACKUP_PATH" ]; then
        fail "Folder backup tidak ditemukan."; pause; return 1
    fi

    acquire_lock || { pause; return 1; }
    trap 'release_lock' EXIT

    case "$RMODE" in
        1)
            for required in panel_db.sql panel_files.zip; do
                if [ ! -f "$BACKUP_PATH/$required" ]; then
                    fail "File backup wajib tidak ada: $required"
                    release_lock; trap - EXIT; pause; return 1
                fi
            done
            ;;
        2) [ -f "$BACKUP_PATH/panel_db.sql" ] || { fail "panel_db.sql tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         3) [ -f "$BACKUP_PATH/panel_files.zip" ] || { fail "panel_files.zip tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         4) [ -d "$BACKUP_PATH/wings_config" ] || { fail "wings_config tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
         5) [ -f "$BACKUP_PATH/server_volumes.zip" ] || { fail "server_volumes.zip tidak ada."; release_lock; trap - EXIT; pause; return 1; } ;;
    esac

    ask_mysql_root_password
    read -r -s -p "Password database untuk user $DB_USER: " DB_PASS
    echo
    local db_pass_sql
    db_pass_sql=$(printf "%s" "$DB_PASS" | sed "s/'/''/g")

    log_msg "Restore dimulai dari: $BACKUP_PATH (mode $RMODE)"
    systemctl stop wings pteroq nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    _restore_abort() {
        fail "$1"
        systemctl start "php${PHP_VERSION}-fpm" nginx pteroq wings 2>/dev/null || true
        notify_detail "RESTORE GAGAL" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") gagal: $1"
        release_lock; trap - EXIT; pause; return 1
    }

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "2" ]; then
        mysql_root -e "
            DROP DATABASE IF EXISTS $DB_NAME;
            CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
            CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$db_pass_sql';
            GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'127.0.0.1';
            FLUSH PRIVILEGES;
        " || { _restore_abort "Gagal menyiapkan database (cek password root)."; return 1; }
        mysql_secure "$DB_USER" "$DB_PASS" -h 127.0.0.1 "$DB_NAME" < "$BACKUP_PATH/panel_db.sql" \
            || { _restore_abort "Restore database gagal."; return 1; }
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "3" ]; then
        rm -rf "$PANEL_DIR"
        unzip -o "$BACKUP_PATH/panel_files.zip" -d /var/www \
            || { _restore_abort "Ekstrak panel_files.zip gagal."; return 1; }
        chown -R www-data:www-data "$PANEL_DIR" 2>/dev/null || true
        chmod -R 755 "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true
        set_env_value TRUSTED_PROXIES "*"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "4" ]; then
        mkdir -p "$WINGS_DIR"
        [ -d "$BACKUP_PATH/wings_config" ] && cp -a "$BACKUP_PATH/wings_config/." "$WINGS_DIR/"
    fi

    if [ "$RMODE" = "1" ] || [ "$RMODE" = "5" ]; then
        mkdir -p /var/lib/pterodactyl/volumes
        if [ -f "$BACKUP_PATH/server_volumes.zip" ]; then
            unzip -o "$BACKUP_PATH/server_volumes.zip" -d /var/lib \
                || { _restore_abort "Ekstrak server_volumes.zip gagal."; return 1; }
        fi
    fi

    # --- Nginx config (sama kaya install.sh, pake domain dari backup) ---
    mkdir -p /etc/certs/panel /etc/nginx/sites-available /etc/nginx/sites-enabled
    local DOMAIN="localhost"
    if [ -f "$BACKUP_PATH/backup.meta" ]; then
        DOMAIN=$(grep -oP '^PANEL_DOMAIN=\K.*' "$BACKUP_PATH/backup.meta" 2>/dev/null || echo "localhost")
    fi
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/C=NA/ST=NA/L=NA/O=NA/CN=${DOMAIN}" \
        -keyout /etc/certs/panel/privkey.pem -out /etc/certs/panel/fullchain.pem 2>/dev/null || true
    cat > /etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;
    ssl_certificate /etc/certs/panel/fullchain.pem;
    ssl_certificate_key /etc/certs/panel/privkey.pem;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize=100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    location ~ /\.ht { deny all; }
}
NGINX
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
    nginx -t && systemctl restart nginx "php${PHP_VERSION}-fpm" 2>/dev/null || true

    systemctl start pteroq wings 2>/dev/null || true
    log_msg "Restore selesai dari: $BACKUP_PATH (mode $RMODE)"
    notify_detail "RESTORE OK" "Restore mode $RMODE dari $(basename "$BACKUP_PATH") selesai."
    echo -e "${GREEN}Restore selesai.${NC}"
    release_lock
    trap - EXIT
    pause
}

function list_backups() {
    require_root || return 1
    header
    echo -e "${BLUE}Daftar backup di $BACKUP_ROOT:${NC}"
    echo
    if [ ! -d "$BACKUP_ROOT" ]; then
        echo "Folder backup belum ada."
    else
        local i=0
        while IFS= read -r bdir; do
            i=$((i+1))
            local size
            size=$(du -sh "$bdir" 2>/dev/null | awk '{print $1}')
            echo -e "  ${CYAN}[$i]${NC} $(basename "$bdir")  ${YELLOW}($size)${NC}"
        done < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
        [ "$i" -eq 0 ] && echo "Backup belum ada."
    fi
    echo
    pause
}

function cleanup_old_backups() {
    [ -d "$BACKUP_ROOT" ] || return 0
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ptero_*' \
        -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} \; 2>/dev/null || true
    local count
    count=$(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null | wc -l)
    if [ "$count" -gt "$BACKUP_MAX_COUNT" ]; then
        ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null \
            | tail -n +"$((BACKUP_MAX_COUNT + 1))" | xargs -r rm -rf
    fi
}

function delete_backup() {
    require_root || return 1
    header
    mapfile -t BACKUPS < <(ls -1dt "$BACKUP_ROOT"/ptero_* 2>/dev/null)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo -e "${YELLOW}Belum ada backup.${NC}"
        pause
        return 0
    fi
    echo -e "${BLUE}Pilih backup yang akan dihapus:${NC}"
    local target
    target=$(pick_from_list "Nomor backup:" "${BACKUPS[@]}") || {
        echo -e "${YELLOW}Dibatalkan.${NC}"; pause; return 0;
    }
    confirm_action "Hapus permanen: $target?" || { echo "Batal."; pause; return 0; }
    rm -rf "$target"
    log_msg "Backup dihapus: $target"
    echo -e "${GREEN}Backup dihapus.${NC}"
    pause
}

function schedule_auto_backup() {
    require_root || return 1
    read -r -s -p "Password database $DB_USER untuk auto backup: " AUTO_DB_PASS
    echo
    if ! validate_db_password "$AUTO_DB_PASS" 8; then
        pause
        return 1
    fi
    read -r -p "Jam backup harian [03:00]: " BACKUP_TIME
    BACKUP_TIME=${BACKUP_TIME:-03:00}
    if ! echo "$BACKUP_TIME" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        fail "Format jam tidak valid (00:00–23:59). Gunakan HH:MM, contoh 03:00."
        pause
        return 1
    fi
    local hour minute script_path
    hour=${BACKUP_TIME%:*}
    minute=${BACKUP_TIME#*:}
    script_path=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    mkdir -p "$(dirname "$AUTO_BACKUP_CNF")"
    chmod 700 "$(dirname "$AUTO_BACKUP_CNF")"
    local _old_umask
    _old_umask=$(umask); umask 077
    {
        printf '[client]\n'
        printf 'user=%s\n' "$DB_USER"
        printf 'password=%s\n' "$AUTO_DB_PASS"
        printf 'host=127.0.0.1\n'
    } > "$AUTO_BACKUP_CNF"
    chmod 600 "$AUTO_BACKUP_CNF"
    umask "$_old_umask"
    cat > "$AUTO_BACKUP_SCRIPT" <<AUTO
#!/bin/bash
exec bash '$script_path' --auto-backup --cnf '$AUTO_BACKUP_CNF'
AUTO
    chmod 700 "$AUTO_BACKUP_SCRIPT"
    setup_logrotate
    cat > /etc/cron.d/ptero-manager-backup <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$minute $hour * * * root $AUTO_BACKUP_SCRIPT >> $LOG_FILE 2>&1
CRON
    systemctl restart cron 2>/dev/null || true
    log_msg "Backup otomatis dijadwalkan setiap $BACKUP_TIME"
    echo -e "${GREEN}Backup otomatis aktif setiap jam $BACKUP_TIME.${NC}"
    echo -e "${YELLOW}Kredensial DB tersimpan di $AUTO_BACKUP_CNF (root-only, mode 600).${NC}"
    pause
}

S3_CONFIG="/root/.ptero-s3.conf"

function backup_s3_setup() {
    require_root || return 1
    header
    echo -e "${BLUE}Setup S3-Compatible Backup Destination${NC}"
    echo -e "${YELLOW}Mendukung: AWS S3, Wasabi, Backblaze B2, MinIO, DO Spaces, dll.${NC}"
    echo

    if [ -f "$S3_CONFIG" ]; then
        echo -e "Konfigurasi S3 saat ini: ${GREEN}(tersimpan)${NC}"
        echo "1) Ubah konfigurasi"
        echo "2) Hapus konfigurasi"
        echo "3) Test upload"
        echo "0) Kembali"
        read -r -p "Pilih [0-3]: " SO
        case "$SO" in
            2) rm -f "$S3_CONFIG"; echo -e "${GREEN}Konfigurasi S3 dihapus.${NC}"; pause; return 0 ;;
            3) backup_s3_test_upload; return 0 ;;
            0) return 0 ;;
        esac
    fi

    echo -e "${CYAN}Masukkan detail S3:${NC}"
    read -r -p "Endpoint URL (contoh https://s3.amazonaws.com): " S3_ENDPOINT
    [ -z "$S3_ENDPOINT" ] && { fail "Endpoint wajib diisi."; pause; return 1; }
    read -r -p "Access Key ID: " S3_ACCESS_KEY
    [ -z "$S3_ACCESS_KEY" ] && { fail "Access Key wajib diisi."; pause; return 1; }
    read -r -s -p "Secret Access Key: " S3_SECRET_KEY
    echo
    [ -z "$S3_SECRET_KEY" ] && { fail "Secret Key wajib diisi."; pause; return 1; }
    read -r -p "Bucket name: " S3_BUCKET
    [ -z "$S3_BUCKET" ] && { fail "Bucket wajib diisi."; pause; return 1; }
    read -r -p "Path prefix (opsional, contoh: backups/ptero): " S3_PREFIX
    read -r -p "Region (opsional, default: us-east-1): " S3_REGION
    S3_REGION=${S3_REGION:-us-east-1}

    local _old_umask
    _old_umask=$(umask); umask 077
    cat > "$S3_CONFIG" <<S3CONF
S3_ENDPOINT="$S3_ENDPOINT"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"
S3_BUCKET="$S3_BUCKET"
S3_PREFIX="$S3_PREFIX"
S3_REGION="$S3_REGION"
S3CONF
    chmod 600 "$S3_CONFIG"
    umask "$_old_umask"

    if ! command -v s3cmd >/dev/null 2>&1; then
        echo -e "${BLUE}[*] Install s3cmd...${NC}"
        DEBIAN_FRONTEND=noninteractive apt install -y s3cmd >/dev/null 2>&1 || true
    fi
    if ! command -v s3cmd >/dev/null 2>&1; then
        echo -e "${YELLOW}s3cmd tidak bisa diinstall. Coba: apt install s3cmd${NC}"
    fi

    log_msg "S3 backup destination configured: $S3_ENDPOINT/$S3_BUCKET"
    echo -e "${GREEN}S3 configuration saved.${NC}"
    echo
    echo "1) Test upload sekarang"
    echo "0) Kembali"
    read -r -p "Pilih [0-1]: " TOPT
    case "$TOPT" in
        1) backup_s3_test_upload ;;
    esac
}

function _s3_upload_file() {
    local local_path="$1"
    local remote_path="$2"
    [ -f "$local_path" ] || return 1

    if [ ! -f "$S3_CONFIG" ]; then
        echo "  ${RED}S3 config not found${NC}"
        return 1
    fi

    source "$S3_CONFIG"

    if ! command -v s3cmd >/dev/null 2>&1; then
        echo "  ${RED}s3cmd tidak terinstall. Jalankan: apt install s3cmd${NC}"
        return 1
    fi

    local ep
    ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
    local ep_host
    ep_host=$(echo "$ep" | sed 's|https\?://||')
    local host_bucket="%(bucket)s.$ep_host"

    # s3cmd >=2.4 butuh file konfigurasi — bikin temp
    local tmpcfg
    tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
    cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG

    local rc
    s3cmd -c "$tmpcfg" put "$local_path" "s3://$S3_BUCKET/$remote_path" 2>&1
    rc=$?
    rm -f "$tmpcfg"
    return $rc
}

function backup_s3_test_upload() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu."
        pause
        return 1
    fi

    source "$S3_CONFIG"
    echo -e "${BLUE}[*] Test upload ke S3 via s3cmd...${NC}"
    echo -e "  Endpoint : ${CYAN}$S3_ENDPOINT${NC}"
    echo -e "  Bucket   : ${CYAN}$S3_BUCKET${NC}"
    echo -e "  Region   : ${CYAN}${S3_REGION:-US}${NC}"
    echo

    local test_file="/tmp/ptero-s3-test-$(date +%s).txt"
    echo "Ptero Manager S3 test at $(date)" > "$test_file"

    local output
    output=$(_s3_upload_file "$test_file" "test/ptero-s3-test.txt" 2>&1)
    local rc=$?

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}[OK] Upload test berhasil.${NC}"
        log_msg "S3 test upload OK"
        notify_detail "S3 TEST" "S3 backup destination test berhasil."
        echo
        echo "1) Hapus file test dari S3"
        read -r -p "Pilih [0-1]: " DEL
        if [ "$DEL" = "1" ]; then
            local ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
            local ep_host=$(echo "$ep" | sed 's|https\?://||')
            local host_bucket="%(bucket)s.$ep_host"
            local tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
            cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG
            s3cmd -c "$tmpcfg" del "s3://$S3_BUCKET/test/ptero-s3-test.txt" >/dev/null 2>&1
            rm -f "$tmpcfg"
        fi
    else
        echo -e "${RED}[FAIL] Upload test gagal (rc=$rc).${NC}"
        echo
        echo -e "${YELLOW}Error dari s3cmd:${NC}"
        echo "$output" | sed 's/^/  /'
        echo
        echo -e "${YELLOW}Penyebab umum:${NC}"
        echo -e "  1. Endpoint salah"
        echo -e "     B2: https://s3.<region>.backblazeb2.com"
        echo -e "     AWS: https://s3.<region>.amazonaws.com"
        echo -e "     Wasabi: https://s3.<region>.wasabisys.com"
        echo -e "  2. Bucket belum dibuat di dashboard"
        echo -e "  3. Access Key / Secret Key tidak punya akses ke bucket"
        echo -e "  4. Region tidak sesuai endpoint"
        echo
        echo -e "${YELLOW}Coba test manual:${NC}"
        echo -e "  apt install s3cmd"
        echo -e "  s3cmd --host=$S3_ENDPOINT --access_key=$S3_ACCESS_KEY ls"
    fi
    rm -f "$test_file"
    pause
}

function backup_to_s3() {
    require_root || return 1
    if ! command -v zip >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt install -y zip >/dev/null 2>&1 || true
    fi
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi

    source "$S3_CONFIG"
    local backup_name="ptero_s3_$(date +%F_%H-%M-%S)"
    local tmp_dir="/tmp/$backup_name"
    mkdir -p "$tmp_dir"

    echo -e "${BLUE}[*] Backup & upload ke S3: $S3_ENDPOINT/$S3_BUCKET${NC}"

    read -r -s -p "Password database $DB_USER: " DBP
    echo

    if mysqldump_secure "$DB_USER" "$DBP" -h 127.0.0.1 "$DB_NAME" > "$tmp_dir/panel_db.sql"; then
        (cd /var/www && zip -r "$tmp_dir/panel_files.zip" pterodactyl) 2>/dev/null || true
        [ -d "$WINGS_DIR" ] && (cd /etc && zip -r "$tmp_dir/wings_config.zip" pterodactyl) 2>/dev/null || true

        local prefix="${S3_PREFIX:+$S3_PREFIX/}"
        local failed=0

        for f in panel_db.sql panel_files.zip wings_config.zip; do
            if [ -f "$tmp_dir/$f" ]; then
                echo -n "  Upload $f ... "
                if _s3_upload_file "$tmp_dir/$f" "${prefix}${backup_name}/$f"; then
                    echo -e "${GREEN}OK${NC}"
                else
                    echo -e "${RED}FAIL${NC}"
                    failed=1
                fi
            fi
        done

        rm -rf "$tmp_dir"

        if [ "$failed" -eq 0 ]; then
            log_msg "S3 backup sukses: $backup_name"
            notify_detail "S3 BACKUP" "Backup ke S3 selesai: $backup_name"
            echo -e "${GREEN}Backup S3 selesai.${NC}"
        else
            log_msg "S3 backup partial: $backup_name"
            notify_detail "S3 BACKUP WARN" "Backup S3 selesai dengan error."
            echo -e "${YELLOW}Backup S3 selesai tapi ada file gagal upload.${NC}"
        fi
    else
        rm -rf "$tmp_dir"
        fail "Backup database gagal."
    fi
    pause
}

function _s3_exec_cmd() {
    source "$S3_CONFIG"
    local ep=$(echo "$S3_ENDPOINT" | sed 's|/$||')
    local ep_host=$(echo "$ep" | sed 's|https\?://||')
    local host_bucket="%(bucket)s.$ep_host"
    local tmpcfg=$(mktemp /tmp/ptero-s3cfg-XXXXXX)
    cat > "$tmpcfg" <<S3CFG
[default]
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY
host_base = $ep_host
host_bucket = $host_bucket
bucket_location = ${S3_REGION:-us-east-1}
use_https = True
check_ssl_certificate = False
check_ssl_hostname = False
S3CFG
    s3cmd -c "$tmpcfg" "$@"
    local rc=$?
    rm -f "$tmpcfg"
    return $rc
}

function s3_list_backups() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"
    echo -e "${BLUE}Daftar backup di S3: $S3_ENDPOINT/$S3_BUCKET${NC}"
    echo
    local output
    output=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1)
    if echo "$output" | grep -q "No such bucket\|ERROR\|Error"; then
        echo -e "${RED}Gagal:${NC}"
        echo "$output" | sed 's/^/  /'
    elif [ -z "$output" ]; then
        echo -e "${YELLOW}Tidak ada backup di S3.${NC}"
    else
        echo "$output" | sed 's/^/  /'
    fi
    pause
}

function s3_restore_backup() {
    require_root || return 1
    if [ ! -f "$S3_CONFIG" ]; then
        fail "Konfigurasi S3 belum ada. Setup dulu (menu 64)."
        pause
        return 1
    fi
    source "$S3_CONFIG"
    local prefix="${S3_PREFIX:+$S3_PREFIX/}"

    echo -e "${BLUE}[*] Mengambil daftar backup dari S3...${NC}"
    echo
    local lines
    lines=$(_s3_exec_cmd ls "s3://$S3_BUCKET/$prefix" 2>&1 | grep -oP 'ptero_s3_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort -u)
    if [ -z "$lines" ]; then
        fail "Tidak ada backup S3 ditemukan."
        pause
        return 1
    fi

    mapfile -t backups <<< "$lines"
    local pick
    pick=$(pick_from_list "Pilih backup:" "${backups[@]}") || {
        echo "Dibatalkan."; pause; return 0
    }

    local tmp_dir="/tmp/s3-restore-$pick"
    mkdir -p "$tmp_dir"

    echo -e "${BLUE}[*] Download backup $pick dari S3...${NC}"
    local failed=0
    for f in panel_db.sql panel_files.zip wings_config.zip; do
        echo -n "  Download $f ... "
        if _s3_exec_cmd get "s3://$S3_BUCKET/$prefix$pick/$f" "$tmp_dir/$f" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${YELLOW}skip (tidak ada)${NC}"
        fi
    done

    if [ ! -f "$tmp_dir/panel_db.sql" ]; then
        rm -rf "$tmp_dir"
        fail "panel_db.sql tidak ada. Backup S3 mungkin korup."
        pause
        return 1
    fi

    # Buat backup.meta biar restore bisa baca domain
    echo "PANEL_DOMAIN=${PANEL_DOMAIN:-localhost}" > "$tmp_dir/backup.meta"

    echo
    echo -e "${GREEN}Download selesai. Memulai restore...${NC}"
    sleep 1

    restore_system "$tmp_dir"

    rm -rf "$tmp_dir"
}
