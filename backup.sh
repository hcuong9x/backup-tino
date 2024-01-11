#!/bin/bash

SERVER_NAME=$(hostname -I | awk '{print $1}')
TIMESTAMP=$(date +"%F")

SECONDS=0
LOG_FILE="/var/log/backup.log"
LOG_FILE_BIN="/var/log/backup_bin.log"

GROUP_ID=<group_id>
BOT_TOKEN=<bot_token>

echo "" > $LOG_FILE
echo "" > $LOG_FILE_BIN

# Function to log errors to the log file
log_error() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - ERROR: $1" >> "$LOG_FILE"
}

# Function to log informational messages to the log file
log_info() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - INFO: $1" >> "$LOG_FILE"
}

log_bin() {
    echo "$1" >> "$LOG_FILE_BIN"
}

backup_domain() {
    local domain_path="$1"
    local domain=$(basename "$(dirname "$domain_path")") # Extract domain name
    local owner_group=$(stat -c "%U:%G" "$domain_path")
    log_info "Backing up $domain"
    
    cd "$domain_path" || {
        log_error "Directory not found: $domain_path"
        return
    }
    echo "$domain_path"
    echo "$domain"
    echo "$owner_group"

    echo "Start for $domain"

    if ! wp --allow-root plugin is-active all-in-one-wp-migration; then
        # Check if the plugin is installed
        if ! wp --allow-root plugin is-installed all-in-one-wp-migration; then
            # Install and activate the plugin
            echo "Install and activate all-in-one-wp-migration"
            wp --allow-root plugin install all-in-one-wp-migration --activate
        else
            # Activate the plugin if it's installed but not active
            echo "Activate all-in-one-wp-migration"
            wp --allow-root plugin update all-in-one-wp-migration
            wp --allow-root plugin activate all-in-one-wp-migration
        fi
        sudo chown -R "$owner_group" /home/"$domain"/public_html/wp-content/plugins/all-in-one-wp-migration/
        sudo chmod -R 755 /home/"$domain"/public_html/wp-content/plugins/all-in-one-wp-migration/
    else
        echo "all-in-one-wp-migration is already active"
    fi

    if ! wp --allow-root plugin is-active all-in-one-wp-migration-unlimited-extension; then
        # Check if the unlimited extension is installed
        if ! wp --allow-root plugin is-installed all-in-one-wp-migration-unlimited-extension; then
            # Upload and install the unlimited extension
            wp --allow-root plugin install "$extension_zip" --activate
        else
            wp --allow-root plugin activate all-in-one-wp-migration-unlimited-extension
        fi
        sudo chown -R "$owner_group" /home/"$domain"/public_html/wp-content/plugins/all-in-one-wp-migration-unlimited-extension/
        sudo chmod -R 755 /home/"$domain"/public_html/wp-content/plugins/all-in-one-wp-migration-unlimited-extension/
    else
        echo "all-in-one-wp-migration-unlimited-extension is already active"
    fi

    echo "Start backup for $domain"
    backup_dir="/home/$domain/public_html/wp-content/ai1wm-backups"
    # remove older backup
    sudo rm -rf "$backup_dir"/*.wpress

    wp ai1wm backup --sites --allow-root --exclude-cache
    # Get the latest backup filename
    cd "$backup_dir" || exit
    latest_backup="$(ls -1t | head -n1)"

    if [ $? -ne 0 ]; then
        log_error "Failed to create backup for $domain"
        log_bin "$domain - source1"
    else
        log_bin "$domain - source0"
    fi

    log_info "Uploading backup for $domain"
    echo "Uploading backup for $domain"
    
    # rclone mkdir
    /usr/bin/rclone move "$backup_dir/$latest_backup" "backup:$SERVER_NAME/$TIMESTAMP" >> "$LOG_FILE" 2>&1
    if [ $? -ne 0 ]; then
        log_error "Failed to upload backup for $domain"
        log_bin "$domain - cloud1"
    else
        log_bin "$domain - cloud0"
    fi
    sudo rm -rf "$backup_dir"/*.wpress
    # Deactivate the All-in-One WP Migration plugins
    wp --allow-root plugin deactivate all-in-one-wp-migration-unlimited-extension
    wp --allow-root plugin deactivate all-in-one-wp-migration

}

log_info "Starting Backup Website"

script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
extension_zip="$script_dir/all-in-one-wp-migration-unlimited-extension.zip"
echo "$extension_zip"

# Check if parameters are provided
if [ "$#" -gt 0 ]; then
    # Loop through each parameter
    for domain_param in "$@"; do
        domain_path="/home/$domain_param/public_html"
        if [ -d "$domain_path" ]; then # If a directory
            backup_domain "$domain_path"
        else
            echo "$domain_param not exits!"
        fi
    done
else
    # Backup all domains in /home/
    for domain_path in /home/*/public_html; do
        [ -d "$domain_path" ] && backup_domain "$domain_path"
    done
fi

log_info "Backup finished"
duration=$SECONDS
log_info "Total $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

while IFS= read -r line; do
    line=$(echo "$line" | awk '{$1=$1};1')
    domain=$(echo "$line" | awk -F ',' '{print $1}')

    if echo "$line" | grep -q "source1"; then
        text="Failed: Backup Source - $domain on $(hostname) IP $(hostname -I)"
        curl -s --data "text=${text}" --data "chat_id=${GROUP_ID}" 'https://api.telegram.org/bot'${BOT_TOKEN}'/sendMessage' > /dev/null
    fi

    if echo "$line" | grep -q "cloud1"; then
        text="Failed: Upload to Cloud - $domain on $(hostname) IP $(hostname -I)"
        curl -s --data "text=${text}" --data "chat_id=${GROUP_ID}" 'https://api.telegram.org/bot'${BOT_TOKEN}'/sendMessage' > /dev/null
    fi

done < "/var/log/backup_bin.log"