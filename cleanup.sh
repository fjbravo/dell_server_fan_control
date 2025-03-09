#!/bin/bash

# Exit on error
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Backup and temp directories
BACKUP_DIR_PREFIX="/tmp/dell-fan-control-backup-"
TEMP_DIR="/tmp/dell-fan-control-install"

# Function to display header
display_header() {
    clear
    echo -e "${BLUE}Dell Server Fan Control Cleanup Utility${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo
}

# Function to display main menu
display_main_menu() {
    display_header
    echo "1. Backup File Management"
    echo "2. Temporary File Cleanup (removes all temp files)"
    echo "3. Combined Cleanup"
    echo "4. Exit"
    echo
    echo -n "Enter your choice [1-4]: "
}

# Function to display backup management menu
display_backup_menu() {
    display_header
    echo "Backup Cleanup Options:"
    echo "1. Keep X most recent backups"
    echo "2. Keep backups from last X days"
    echo "3. Back to main menu"
    echo
    echo -n "Enter your choice [1-3]: "
}

# Function to find all backup directories
find_backup_dirs() {
    find /tmp -maxdepth 1 -type d -name "dell-fan-control-backup-*" | sort
}

# Function to find all temp files
find_temp_files() {
    # Find the main temp directory
    if [ -d "$TEMP_DIR" ]; then
        find "$TEMP_DIR" -type f 2>/dev/null
    fi
    
    # Find any stray temp files from config validation
    find /tmp -maxdepth 1 -type f -name "tmp.*" -exec grep -l "dell-fan-control" {} \; 2>/dev/null || true
}

# Function to keep X most recent backups
process_keep_recent() {
    local keep_count=$1
    local all_backups=($(find_backup_dirs))
    local total=${#all_backups[@]}
    
    if [ $total -eq 0 ]; then
        echo -e "${YELLOW}No backup directories found.${NC}"
        return 0
    fi
    
    # Calculate which backups to keep and which to remove
    local to_remove=()
    local to_keep=()
    
    if [ $total -le $keep_count ]; then
        # Keep all backups if we have fewer than requested
        to_keep=("${all_backups[@]}")
    else
        # Sort backups by date (newest first)
        local sorted_backups=($(printf '%s\n' "${all_backups[@]}" | sort -r))
        
        # Keep the most recent ones
        for ((i=0; i<keep_count; i++)); do
            to_keep+=("${sorted_backups[$i]}")
        done
        
        # Mark the rest for removal
        for ((i=keep_count; i<total; i++)); do
            to_remove+=("${sorted_backups[$i]}")
        done
    fi
    
    # Preview changes
    echo -e "${BLUE}Backup Files:${NC}"
    
    if [ ${#to_remove[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backups will be removed.${NC}"
    else
        echo -e "${RED}Files to be removed:${NC}"
        for dir in "${to_remove[@]}"; do
            echo "  - $dir"
        done
    fi
    
    echo -e "${GREEN}Files to be kept:${NC}"
    for dir in "${to_keep[@]}"; do
        echo "  - $dir"
    done
    
    # Return the list of directories to remove
    if [ ${#to_remove[@]} -gt 0 ]; then
        echo "${to_remove[@]}"
    fi
}

# Function to keep backups from last X days
process_keep_days() {
    local keep_days=$1
    local all_backups=($(find_backup_dirs))
    local total=${#all_backups[@]}
    local cutoff_time=$(date -d "$keep_days days ago" +%s)
    
    if [ $total -eq 0 ]; then
        echo -e "${YELLOW}No backup directories found.${NC}"
        return 0
    fi
    
    # Calculate which backups to keep and which to remove
    local to_remove=()
    local to_keep=()
    
    for dir in "${all_backups[@]}"; do
        # Extract date from directory name
        local dir_date=$(basename "$dir" | sed 's/dell-fan-control-backup-//')
        local dir_timestamp=$(date -d "${dir_date:0:8} ${dir_date:9:2}:${dir_date:11:2}:${dir_date:13:2}" +%s 2>/dev/null)
        
        if [ -z "$dir_timestamp" ]; then
            # If we can't parse the date, use file modification time
            dir_timestamp=$(stat -c %Y "$dir")
        fi
        
        if [ $dir_timestamp -ge $cutoff_time ]; then
            to_keep+=("$dir")
        else
            to_remove+=("$dir")
        fi
    done
    
    # Preview changes
    echo -e "${BLUE}Backup Files:${NC}"
    
    if [ ${#to_remove[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backups will be removed.${NC}"
    else
        echo -e "${RED}Files to be removed:${NC}"
        for dir in "${to_remove[@]}"; do
            echo "  - $dir"
        done
    fi
    
    echo -e "${GREEN}Files to be kept:${NC}"
    for dir in "${to_keep[@]}"; do
        echo "  - $dir"
    done
    
    # Return the list of directories to remove
    if [ ${#to_remove[@]} -gt 0 ]; then
        echo "${to_remove[@]}"
    fi
}

# Function to process temp files
process_temp_files() {
    local temp_files=($(find_temp_files))
    
    if [ ${#temp_files[@]} -eq 0 ]; then
        echo -e "${YELLOW}No temporary files found.${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Temporary Files to Remove:${NC}"
    for file in "${temp_files[@]}"; do
        echo "  - $file"
    done
    
    # Return the list of files to remove
    echo "${temp_files[@]}"
}

# Function to execute backup cleanup
execute_backup_cleanup() {
    local dirs_to_remove=($@)
    
    if [ ${#dirs_to_remove[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backup directories to remove.${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Removing backup directories...${NC}"
    for dir in "${dirs_to_remove[@]}"; do
        echo -n "  - Removing $dir... "
        if rm -rf "$dir" 2>/dev/null; then
            echo -e "${GREEN}Done${NC}"
        else
            echo -e "${RED}Failed${NC}"
        fi
    done
    
    echo -e "${GREEN}Backup cleanup completed.${NC}"
}

# Function to execute temp file cleanup
execute_temp_cleanup() {
    local files_to_remove=($@)
    
    if [ ${#files_to_remove[@]} -eq 0 ]; then
        echo -e "${YELLOW}No temporary files to remove.${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Removing temporary files...${NC}"
    for file in "${files_to_remove[@]}"; do
        echo -n "  - Removing $file... "
        if rm -f "$file" 2>/dev/null; then
            echo -e "${GREEN}Done${NC}"
        else
            echo -e "${RED}Failed${NC}"
        fi
    done
    
    # Also remove the temp directory if it exists
    if [ -d "$TEMP_DIR" ]; then
        echo -n "  - Removing $TEMP_DIR... "
        if rm -rf "$TEMP_DIR" 2>/dev/null; then
            echo -e "${GREEN}Done${NC}"
        else
            echo -e "${RED}Failed${NC}"
        fi
    fi
    
    echo -e "${GREEN}Temporary file cleanup completed.${NC}"
}

# Function to handle backup management
handle_backup_management() {
    local choice
    local keep_count
    local keep_days
    local dirs_to_remove
    
    while true; do
        display_backup_menu
        read -r choice
        
        case $choice in
            1)  # Keep X most recent backups
                echo
                echo -n "Enter number of recent backups to keep: "
                read -r keep_count
                
                if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || [ "$keep_count" -lt 0 ]; then
                    echo -e "${RED}Error: Please enter a valid positive number.${NC}"
                    read -p "Press Enter to continue..."
                    continue
                fi
                
                echo
                dirs_to_remove=($(process_keep_recent $keep_count))
                
                if [ ${#dirs_to_remove[@]} -gt 0 ]; then
                    echo
                    echo -n "Proceed with cleanup? [Y/n]: "
                    read -r confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]] || [ -z "$confirm" ]; then
                        execute_backup_cleanup "${dirs_to_remove[@]}"
                    else
                        echo -e "${YELLOW}Cleanup cancelled.${NC}"
                    fi
                fi
                
                read -p "Press Enter to continue..."
                break
                ;;
                
            2)  # Keep backups from last X days
                echo
                echo -n "Enter number of days of backups to keep: "
                read -r keep_days
                
                if ! [[ "$keep_days" =~ ^[0-9]+$ ]] || [ "$keep_days" -lt 0 ]; then
                    echo -e "${RED}Error: Please enter a valid positive number.${NC}"
                    read -p "Press Enter to continue..."
                    continue
                fi
                
                echo
                dirs_to_remove=($(process_keep_days $keep_days))
                
                if [ ${#dirs_to_remove[@]} -gt 0 ]; then
                    echo
                    echo -n "Proceed with cleanup? [Y/n]: "
                    read -r confirm
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]] || [ -z "$confirm" ]; then
                        execute_backup_cleanup "${dirs_to_remove[@]}"
                    else
                        echo -e "${YELLOW}Cleanup cancelled.${NC}"
                    fi
                fi
                
                read -p "Press Enter to continue..."
                break
                ;;
                
            3)  # Back to main menu
                return
                ;;
                
            *)  # Invalid choice
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Function to handle temp file cleanup
handle_temp_cleanup() {
    local files_to_remove
    
    echo
    files_to_remove=($(process_temp_files))
    
    if [ ${#files_to_remove[@]} -gt 0 ]; then
        echo
        echo -n "Proceed with cleanup? [Y/n]: "
        read -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]] || [ -z "$confirm" ]; then
            execute_temp_cleanup "${files_to_remove[@]}"
        else
            echo -e "${YELLOW}Cleanup cancelled.${NC}"
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# Function to handle combined cleanup
handle_combined_cleanup() {
    local choice
    local keep_count
    local keep_days
    local backup_dirs_to_remove
    local temp_files_to_remove
    
    display_header
    echo "Combined Cleanup Options:"
    echo "1. Keep X most recent backups"
    echo "2. Keep backups from last X days"
    echo
    echo -n "Enter your choice [1-2]: "
    read -r choice
    
    case $choice in
        1)  # Keep X most recent backups
            echo
            echo -n "Enter number of recent backups to keep: "
            read -r keep_count
            
            if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || [ "$keep_count" -lt 0 ]; then
                echo -e "${RED}Error: Please enter a valid positive number.${NC}"
                read -p "Press Enter to continue..."
                return
            fi
            
            echo
            echo -e "${BLUE}Preview of actions:${NC}"
            echo
            backup_dirs_to_remove=($(process_keep_recent $keep_count))
            echo
            temp_files_to_remove=($(process_temp_files))
            ;;
            
        2)  # Keep backups from last X days
            echo
            echo -n "Enter number of days of backups to keep: "
            read -r keep_days
            
            if ! [[ "$keep_days" =~ ^[0-9]+$ ]] || [ "$keep_days" -lt 0 ]; then
                echo -e "${RED}Error: Please enter a valid positive number.${NC}"
                read -p "Press Enter to continue..."
                return
            fi
            
            echo
            echo -e "${BLUE}Preview of actions:${NC}"
            echo
            backup_dirs_to_remove=($(process_keep_days $keep_days))
            echo
            temp_files_to_remove=($(process_temp_files))
            ;;
            
        *)  # Invalid choice
            echo -e "${RED}Invalid choice. Please try again.${NC}"
            read -p "Press Enter to continue..."
            return
            ;;
    esac
    
    if [ ${#backup_dirs_to_remove[@]} -gt 0 ] || [ ${#temp_files_to_remove[@]} -gt 0 ]; then
        echo
        echo -n "Proceed with combined cleanup? [Y/n]: "
        read -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]] || [ -z "$confirm" ]; then
            if [ ${#backup_dirs_to_remove[@]} -gt 0 ]; then
                execute_backup_cleanup "${backup_dirs_to_remove[@]}"
            fi
            
            if [ ${#temp_files_to_remove[@]} -gt 0 ]; then
                execute_temp_cleanup "${temp_files_to_remove[@]}"
            fi
            
            echo -e "${GREEN}Combined cleanup completed.${NC}"
        else
            echo -e "${YELLOW}Cleanup cancelled.${NC}"
        fi
    fi
    
    read -p "Press Enter to continue..."
}

# Main function
main() {
    local choice
    
    while true; do
        display_main_menu
        read -r choice
        
        case $choice in
            1)  # Backup File Management
                handle_backup_management
                ;;
                
            2)  # Temporary File Cleanup
                handle_temp_cleanup
                ;;
                
            3)  # Combined Cleanup
                handle_combined_cleanup
                ;;
                
            4)  # Exit
                display_header
                echo -e "${GREEN}Thank you for using Dell Server Fan Control Cleanup Utility.${NC}"
                echo
                exit 0
                ;;
                
            *)  # Invalid choice
                echo -e "${RED}Invalid choice. Please try again.${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# Start the script
main
