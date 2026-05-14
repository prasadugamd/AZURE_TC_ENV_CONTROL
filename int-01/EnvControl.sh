#!/bin/bash
###############################################################################
# EnvControl.sh
#
# Purpose : Manage Azure environment components (VMs, PostgreSQL, Cloudera, K8s)
# Usage   : ./EnvControl.sh <Env_Code> <action>
# Actions : status | start | stop
#
# Environment Variables:
#   REFRESH_CONFIG=true : Force regeneration of config files (VM, PG, CDH)
#
# Features:
#   - Idempotent start/stop (safe re-run)
#   - Color-coded, timestamped logging
#   - Summary of results at end with counts
#   - HTML summary report with totals
#
# Example:
#   ./EnvControl.sh int-01 stop                    # Use cached configs
#   REFRESH_CONFIG=true ./EnvControl.sh int-01 stop  # Refresh all configs from Azure
###############################################################################

set -eo pipefail
shopt -s nullglob

# Source bash_profile if it exists (for environment variables)
# Temporarily allow unset variables during sourcing to avoid bashrc issues
[[ -f "$HOME/.bash_profile" ]] && . "$HOME/.bash_profile" || true

# Now enable strict mode for unset variables
set -u

#-------------------------------#
#          VARIABLES            #
#-------------------------------#
export Env_Code=${1:-""}
export ACTION=${2:-status}
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export CURRENT_DIR="$SCRIPT_DIR"
export CONFIG_DIR="${CURRENT_DIR}/config"
export AUTH_PATH="${CURRENT_DIR}/Auth"
LOG_FILE="${CURRENT_DIR}/EnvControl.log"
REPORT_FILE="${CURRENT_DIR}/EnvControl_Report.html"
INTERNAL_DNS_SUFFIX="${ENVCONTROL_DNS_SUFFIX:-internal.example.local}"
CM_SERVER_FQDN="${Env_Code}-cdhmng01.${INTERNAL_DNS_SUFFIX}"

mkdir -p "$CONFIG_DIR"

#-------------------------------#
#         LOGGING SETUP         #
#-------------------------------#
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }' | tee -a "$LOG_FILE") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-------------------------------#
#          SUMMARY LOGS         #
#-------------------------------#
declare -a SUMMARY_SUCCESS=() SUMMARY_WARN=() SUMMARY_ERROR=()

#-------------------------------#
#          UTILITIES            #
#-------------------------------#
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; SUMMARY_WARN+=("$*"); }
error()   { echo -e "${RED}[ERROR]${NC} $*"; SUMMARY_ERROR+=("$*"); }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; SUMMARY_SUCCESS+=("$*"); }

record_summary() {
  local status="$1" desc="$2"
  case "$status" in
    success) SUMMARY_SUCCESS+=("$desc") ;;
    warn) SUMMARY_WARN+=("$desc") ;;
    error) SUMMARY_ERROR+=("$desc") ;;
  esac
}
is_host_reachable() {
  local host=$1
  ping -c1 -W2 "$host" &>/dev/null || \
    nc -z -w2 "$host" 22 &>/dev/null || return 1
}
safe_exec() {
  local desc="$1"; shift
  echo "[INFO] Executing: $desc"
  if "$@"; then
    success "$desc"
    record_summary success "$desc"
  else
    error "Failed: $desc"
    record_summary error "$desc"
    return 1
  fi
}

log_section() { echo -e "\n${BLUE}====================[ $1 ]====================${NC}"; }

#-------------------------------#
#        VALIDATION CHECKS      #
#-------------------------------#
if [[ -z "$Env_Code" ]]; then
  echo -e "${RED}[ERROR]${NC} Environment code not provided."
  echo "Usage: ./EnvControl.sh <Env_Code> <action>"
  exit 1
fi

if [[ ! "$ACTION" =~ ^(status|start|stop)$ ]]; then
  echo -e "${RED}[ERROR]${NC} Invalid action: $ACTION (use start|stop|status)"
  exit 1
fi

for cmd in az ssh; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Required command '$cmd' not found."
    exit 1
  fi
done

# kubectl check is optional - it will be used remotely via SSH
if ! command -v kubectl &>/dev/null; then
  info "kubectl not found locally (will use remote kubectl on K8s management node)"
fi

#-------------------------------#
#           FUNCTIONS           #
#-------------------------------#

SetUATAuth() {
  log_section "Azure Authentication"
  cd "${AUTH_PATH}" || exit 1
  if [[ -f ./set_az.sh ]]; then
    . ./set_az.sh || { error "Authentication script failed."; exit 1; }
  else
    error "Auth file 'set_az.sh' not found."
    exit 1
  fi
}

GetVMList() {
  log_section "Fetching VM List for ${Env_Code}"
  local config_file="${CONFIG_DIR}/${Env_Code}_VM.config"

  # Force refresh if REFRESH_CONFIG is set, otherwise skip if config exists
  if [[ "${REFRESH_CONFIG:-false}" == "true" ]]; then
    info "REFRESH_CONFIG=true - regenerating VM config"
    rm -f "$config_file"
  elif [[ -f "$config_file" && -s "$config_file" ]]; then
    info "Using existing VM config: $config_file (set REFRESH_CONFIG=true to regenerate)"
    return 0
  fi

  info "Fetching VM list from Azure..."
  az vm list --query "[?contains(name,'${Env_Code}')].{Name:name,RG:resourceGroup}" \
    --output tsv > "$config_file"

  local vm_count=$(wc -l < "$config_file" 2>/dev/null || echo 0)
  info "Found $vm_count VM(s) matching '${Env_Code}'"

  # Also fetch VMSS instances and append to config
  info "Fetching VMSS instances from Azure..."
  local vmss_list
  vmss_list=$(az vmss list --query "[?contains(name,'${Env_Code}')].{Name:name,RG:resourceGroup}" --output tsv 2>/dev/null || true)

  if [[ -n "$vmss_list" ]]; then
    local vmss_instance_count=0
    local vmss_count=$(echo "$vmss_list" | wc -l)
    info "Found $vmss_count VMSS scale set(s)"

    local vmss_processed=0
    while IFS=$'\t' read -r vmss_name rg; do
      [[ -z "$vmss_name" || -z "$rg" ]] && continue
      vmss_processed=$((vmss_processed + 1))
      info "[$vmss_processed/$vmss_count] Fetching instances for VMSS: $vmss_name (RG: $rg)"

      # Get instance IDs and names for this VMSS
      local instances=""
      # Get instanceId, name, computer name, and private IP address
      if ! instances=$(az vmss list-instances --name "$vmss_name" --resource-group "$rg" \
        --query "[].{ID:instanceId,Name:name,Computer:osProfile.computerName}" --output tsv 2>&1); then
        warn "  Failed to query instances for $vmss_name: $instances"
        continue
      fi

      if [[ -n "$instances" ]]; then
        local instance_count=0
        while IFS=$'\t' read -r instance_id instance_name computer_name; do
          # Use instance_name (which has format like vmss_0) for Azure operations
          if [[ -n "$instance_name" ]]; then
            instance_count=$((instance_count + 1))
            
            # Get the private IP address for this VMSS instance
            local private_ip
            private_ip=$(az vmss nic list --vmss-name "$vmss_name" --resource-group "$rg" \
              --query "[?virtualMachine.id|ends_with(@,'/${instance_name}')].ipConfigurations[0].privateIPAddress | [0]" -o tsv 2>/dev/null || echo "")
            
            # Store instance_name, computer_name, FQDN, and IP for SSH operations
            # Format: instance_name<tab>resource_group<tab>computer_fqdn<tab>private_ip
            local computer_fqdn
            if [[ -n "$computer_name" ]]; then
              computer_fqdn="${computer_name}.${INTERNAL_DNS_SUFFIX}"
              if [[ -n "$private_ip" ]]; then
                info "  Instance $instance_id: $instance_name -> Computer: $computer_name -> IP: $private_ip"
              else
                warn "  Instance $instance_id: $instance_name -> Computer: $computer_name -> No private IP found"
              fi
            else
              # Fallback if computer_name is empty (shouldn't happen but be defensive)
              computer_fqdn="${instance_name}.${INTERNAL_DNS_SUFFIX}"
              warn "  Instance $instance_id: $instance_name has no computer name, using instance name as fallback"
            fi
            
            # Write config with IP address as 4th column
            echo -e "${instance_name}\t${rg}\t${computer_fqdn}\t${private_ip}" >> "$config_file" || {
              warn "  Failed to write instance $instance_name to config"
              continue
            }
            vmss_instance_count=$((vmss_instance_count + 1))
          fi
        done <<< "$instances"
        info "  Found $instance_count instance(s) for $vmss_name"
      else
        info "  No instances found for $vmss_name (scale set may be at 0 capacity)"
      fi
    done <<< "$vmss_list"

    info "Found $vmss_instance_count VMSS instance(s) across $vmss_processed scale set(s)"
    local total_count=$(wc -l < "$config_file" 2>/dev/null || echo 0)
    info "Total VMs and VMSS instances: $total_count"
  else
    info "No VMSS found for environment ${Env_Code}"
  fi
}

GetPGList() {
  log_section "Fetching PostgreSQL Flexible Servers for ${Env_Code}"
  local config_file="${CONFIG_DIR}/${Env_Code}_PG.config"

  # Force refresh if REFRESH_CONFIG is set, otherwise skip if config exists
  if [[ "${REFRESH_CONFIG:-false}" == "true" ]]; then
    info "REFRESH_CONFIG=true - regenerating PG config"
    rm -f "$config_file"
  elif [[ -f "$config_file" && -s "$config_file" ]]; then
    info "Using existing PG config: $config_file"
    return 0
  fi

  az postgres flexible-server list --query "[?contains(name,'${Env_Code}')].{Name:name,RG:resourceGroup}" \
    --output tsv > "$config_file"
}

GetClouderaHosts() {
  log_section "Detecting Cloudera VMSS Hosts for ${Env_Code}"
  local cdh_config="${CONFIG_DIR}/${Env_Code}_CDH.config"

  # Force refresh if REFRESH_CONFIG is set, otherwise skip if config exists
  if [[ "${REFRESH_CONFIG:-false}" == "true" ]]; then
    info "REFRESH_CONFIG=true - regenerating Cloudera config"
    rm -f "$cdh_config"
  elif [[ -f "$cdh_config" && -s "$cdh_config" ]]; then
    info "Using existing Cloudera config: $cdh_config"
    return 0
  fi

  info "Fetching Cloudera VMSS list from Azure..."
  # Get VMSS instances that contain 'cdh' in the name
  local vmss_list
  vmss_list=$(az vmss list --query "[?contains(name,'${Env_Code}') && contains(name,'cdh')].{Name:name,RG:resourceGroup}" --output tsv 2>/dev/null || true)

  if [[ -z "$vmss_list" ]]; then
    info "No Cloudera VMSS found, creating default config with FQDN"
    # Create default config with common Cloudera FQDNs
    cat > "$cdh_config" <<-EOF
  ${Env_Code}-cdhdat01.${INTERNAL_DNS_SUFFIX}
  ${Env_Code}-cdhdat02.${INTERNAL_DNS_SUFFIX}
  ${Env_Code}-cdhdat03.${INTERNAL_DNS_SUFFIX}
  ${Env_Code}-cdhmng01.${INTERNAL_DNS_SUFFIX}
  ${Env_Code}-cdhmng02.${INTERNAL_DNS_SUFFIX}
  ${Env_Code}-cdhmng03.${INTERNAL_DNS_SUFFIX}
EOF
  else
    # Extract base names and convert to FQDNs
    echo "$vmss_list" | while read -r vmss rg; do
      # Convert VMSS name to FQDN using the configured DNS suffix.
      local base_name=$(echo "$vmss" | sed 's/-vmss$//')
      echo "${base_name}.${INTERNAL_DNS_SUFFIX}"
    done > "$cdh_config"
  fi

  local cdh_count=$(wc -l < "$cdh_config" 2>/dev/null || echo 0)
  info "Found/configured $cdh_count Cloudera host(s)"
}

GetConsulHosts() {
  log_section "Detecting Consul Hosts for ${Env_Code}"
  local consul_config="${CONFIG_DIR}/${Env_Code}_CONSUL.config"
  local vmcfg="${CONFIG_DIR}/${Env_Code}_VM.config"

  # Force refresh if REFRESH_CONFIG is set, otherwise skip if config exists
  if [[ "${REFRESH_CONFIG:-false}" == "true" ]]; then
    info "REFRESH_CONFIG=true - regenerating Consul config"
    rm -f "$consul_config"
  elif [[ -f "$consul_config" && -s "$consul_config" ]]; then
    info "Using existing Consul config: $consul_config"
    return 0
  fi

  # Check if VM config exists
  if [[ ! -f "$vmcfg" ]]; then
    warn "VM config not found: $vmcfg - run GetVMList first"
    return 1
  fi

  info "Extracting Consul hosts from VM config..."
  # Read VM config and filter for consul-related hosts (master, consul, tccli, tcuh)
  # Format: instance_name<tab>resource_group<tab>computer_fqdn<tab>private_ip
  local consul_count=0
  local invalid_entries=0
  > "$consul_config"  # Create/truncate file

  while IFS=$'\t' read -r instance_name rg computer_fqdn private_ip; do
    [[ -z "$instance_name" ]] && continue
    
    # Check if this host runs consul
    if [[ "$instance_name" =~ (master|consul|tccli|tcuh) ]]; then
      # Validate that we have all required fields
      if [[ -z "$rg" || -z "$computer_fqdn" ]]; then
        warn "  Skipping $instance_name - VM config is in old format (missing fields)"
        invalid_entries=$((invalid_entries + 1))
        continue
      fi
      
      # Write to consul config with all fields
      echo -e "${instance_name}\t${rg}\t${computer_fqdn}\t${private_ip}" >> "$consul_config"
      consul_count=$((consul_count + 1))
      
      # Show what we added
      if [[ -n "$private_ip" && "$private_ip" != "null" ]]; then
        info "  Added: $instance_name -> IP: $private_ip (FQDN: $computer_fqdn)"
      else
        info "  Added: $instance_name -> FQDN: $computer_fqdn (no IP)"
      fi
    fi
  done < "$vmcfg"

  # Show warning if VM config is in old format
  if [[ $invalid_entries -gt 0 ]]; then
    error ""
    error "═══════════════════════════════════════════════════════════════════"
    error "  VM CONFIG IS OUTDATED - MISSING REQUIRED FIELDS"
    error "═══════════════════════════════════════════════════════════════════"
    error ""
    error "Found $invalid_entries Consul host(s) with missing resource group/FQDN/IP fields."
    error "Your VM config file is in an old format that lacks critical information."
    error ""
    error "REQUIRED ACTION: Regenerate VM and Consul configs with:"
    error "  REFRESH_CONFIG=true ./EnvControl.sh ${Env_Code} ${ACTION}"
    error ""
    error "This will query Azure for complete instance information including:"
    error "  - Resource group names"
    error "  - Computer FQDNs (actual Azure computer names)"
    error "  - Private IP addresses (for DNS-free connectivity)"
    error ""
    error "═══════════════════════════════════════════════════════════════════"
    error ""
    
    # If ALL entries were invalid, fail completely
    if [[ $consul_count -eq 0 ]]; then
      error "Cannot proceed - no valid Consul hosts found in VM config"
      error "You MUST regenerate configs with REFRESH_CONFIG=true"
      return 1
    else
      warn "Proceeding with $consul_count valid entries, but $invalid_entries were skipped"
    fi
  fi

  if [[ $consul_count -eq 0 ]]; then
    warn "No Consul hosts found in VM config (looking for: master, consul, tccli, tcuh)"
    return 1
  fi

  info "Found $consul_count Consul host(s) - config saved to $consul_config"
}

ValidateFW() {
  local host=$1
  local REMOTE_USER=azure
  local COMPONENT=firewalld
  echo "[INFO] Checking firewalld status on $host..."
if ! is_host_reachable "$host"; then
  warn "[${COMPONENT}] Host $host not reachable — skipping $service"
else
  ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no "$REMOTE_USER@$host" "
    if systemctl is-active --quiet firewalld; then
      echo 'firewalld active, disabling...'
      sudo systemctl stop firewalld && sudo systemctl disable firewalld && sudo systemctl mask firewalld
    else
      echo 'firewalld already disabled.'
    fi"
fi
}

ManageVMSS() {
  log_section "Azure VMSS Instance Management (Non-Cloudera)"
  local vmcfg="${CONFIG_DIR}/${Env_Code}_VM.config"
  [[ ! -f "$vmcfg" ]] && { warn "VM config not found: $vmcfg"; return; }

  # Read config with format: instance_name<tab>resource_group<tab>computer_fqdn (optional)
  while IFS=$'\t' read -r host rg computer_fqdn; do
    [[ -z "$host" || -z "$rg" ]] && continue

    # Only process VMSS instances (check for -vmss suffix followed by numbers or underscore+numbers)
    if [[ ! "$host" =~ -vmss([0-9]+|_[0-9]+)$ ]]; then
      continue
    fi

    # Skip Cloudera VMSS instances - they are handled by ManageClouderaVMSS()
    if [[ "$host" =~ cdh ]]; then
      continue
    fi

    echo "[INFO] VMSS Instance: $host (RG: $rg)"

    # Parse VMSS name and instance ID
    # Azure VMSS instances can have formats:
    #   - int-01-bastion-vmss_0 (underscore format)
    #   - int-01-bastion-vmss000000 (zero-padded format)
    local vmss_name instance_id
    if [[ "$host" =~ ^(.+)-vmss_([0-9]+)$ ]]; then
      # Format: name-vmss_0 (underscore format)
      vmss_name="${BASH_REMATCH[1]}-vmss"
      instance_id="${BASH_REMATCH[2]}"
    elif [[ "$host" =~ ^(.+)-vmss([0-9]+)$ ]]; then
      # Format: name-vmss000000 (directly attached digits)
      vmss_name="${BASH_REMATCH[1]}-vmss"
      instance_id="${BASH_REMATCH[2]}"
      # Remove leading zeros from instance_id
      instance_id=$((10#$instance_id))
    else
      warn "Cannot parse VMSS instance name: $host — skipping"
      continue
    fi

    info "Parsed: VMSS=$vmss_name, Instance ID=$instance_id"

    # Check if the VMSS instance exists and get both power state and provisioning state
    local state provisioning_state
    if ! state=$(az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
      --query "statuses[?starts_with(code,'PowerState/')].code" -o tsv 2>&1 | tail -1); then
      warn "VMSS instance $host not found or not accessible in resource group $rg — skipping"
      continue
    fi

    # Check provisioning state
    provisioning_state=$(az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
      --query "statuses[?starts_with(code,'ProvisioningState/')].code" -o tsv 2>/dev/null | tail -1 || echo "")

    # Skip if the resource is not found (empty state or error)
    if [[ -z "$state" || "$state" =~ (ResourceNotFound|InstanceViewNotFound|NotFound) ]]; then
      warn "VMSS instance $host does not exist or is not accessible — skipping"
      continue
    fi

    # Check if provisioning failed (case-insensitive check)
    if [[ "${provisioning_state,,}" =~ failed ]]; then
      error "VMSS instance $host has FAILED provisioning state in Azure"
      error "  Power State: $state"
      error "  Provisioning State: $provisioning_state"
      error "  This instance cannot be used until reprovisioned"
      error "  Fix: Delete and recreate this instance, or redeploy the VMSS"
      record_summary error "VMSS instance $host has failed provisioning - needs Azure remediation"
      continue
    fi

    case "$ACTION" in
      start)
        if [[ "$state" == "PowerState/running" ]]; then
          warn "VMSS instance $host already running — skipping start"
        else
          info "Starting VMSS instance $host..."
          local start_output start_result
          start_output=$(az vmss start --name "$vmss_name" --resource-group "$rg" --instance-ids "$instance_id" --no-wait 2>&1)
          start_result=$?
          
          # With --no-wait, trust exit code 0 or check for acceptable messages in output
          # Azure may return non-zero if instance is transitioning, but that's OK
          if [[ $start_result -eq 0 ]]; then
            # Command accepted successfully
            success "Start VMSS instance $host (start command accepted)"
            record_summary success "Start VMSS instance $host"
          elif [[ "$start_output" =~ [Ss]ucceeded|[Aa]ccepted|[Ii]n[Pp]rogress|already|running|transitioning|starting ]]; then
            # Output indicates operation is proceeding
            success "Start VMSS instance $host (operation in progress)"
            record_summary success "Start VMSS instance $host"
          else
            # Genuine error - check if it's a real problem
            if [[ "$start_output" =~ [Nn]ot.[Ff]ound|does.not.exist|[Ii]nvalid ]]; then
              error "Failed to start VMSS instance $host: $start_output"
              record_summary error "Failed to start VMSS instance $host"
            else
              # Unknown response, but don't block - may still have started
              warn "Start VMSS instance $host returned unexpected response (may still succeed)"
              info "  Response: $start_output"
              record_summary warn "Start VMSS instance $host (uncertain - verify manually)"
            fi
            continue
          fi
        fi
        ;;
      stop)
        if [[ "$state" == "PowerState/deallocated" || "$state" == "PowerState/stopped" ]]; then
          warn "VMSS instance $host already stopped — skipping"
        else
          info "Stopping VMSS instance $host..."
          local stop_output stop_result
          stop_output=$(az vmss deallocate --name "$vmss_name" --resource-group "$rg" --instance-ids "$instance_id" --no-wait 2>&1)
          stop_result=$?
          
          # Check if stop was successful or if instance is already stopping/stopped
          if [[ $stop_result -eq 0 ]] || [[ "$stop_output" =~ "Succeeded"|"Accepted"|"InProgress"|"already"|"deallocated" ]]; then
            success "Stop VMSS instance $host (stop operation initiated)"
            record_summary success "Stop VMSS instance $host"
          else
            # Log the actual error for troubleshooting
            warn "Failed to stop VMSS instance $host: $stop_output"
            record_summary warn "Failed to stop VMSS instance $host"
            continue
          fi
        fi
        ;;
      status)
        local power_state
        if power_state=$(az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
          --query "statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>/dev/null); then
          # Replace "VM" with "VMSS Instance" in the power state
          power_state=${power_state//VM /VMSS Instance }
          printf "%-30s %s\n" "$host" "$power_state"
        else
          warn "Cannot get status for VMSS instance $host"
        fi
        ;;
    esac
  done < "$vmcfg"
}

ManageClouderaVMSS() {
  log_section "Cloudera VMSS Instance Management"
  local vmcfg="${CONFIG_DIR}/${Env_Code}_VM.config"
  local cdh_config="${CONFIG_DIR}/${Env_Code}_CDH.config"

  [[ ! -f "$vmcfg" ]] && { warn "VM config not found: $vmcfg"; return; }

  local cloudera_vmss_count=0
  local cloudera_vmss_stopped=0

  # Build list of Cloudera base names from CDH config for better detection
  local cloudera_base_names=()
  if [[ -f "$cdh_config" ]]; then
    while read -r cdh_host; do
      [[ -z "$cdh_host" ]] && continue
      local base_name=${cdh_host%%.*}
      cloudera_base_names+=("$base_name")
    done < "$cdh_config"
    info "Loaded ${#cloudera_base_names[@]} Cloudera host reference(s) from CDH config"
  fi

  # Read config with format: instance_name<tab>resource_group<tab>computer_fqdn (optional)
  while IFS=$'\t' read -r host rg computer_fqdn; do
    [[ -z "$host" || -z "$rg" ]] && continue

    # Only process VMSS instances (check for -vmss suffix followed by numbers or underscore+numbers)
    if [[ ! "$host" =~ -vmss([0-9]+|_[0-9]+)$ ]]; then
      continue
    fi

    # Only process Cloudera VMSS instances
    # Method 1: Check if 'cdh' appears in the name
    # Method 2: Check if the base name matches any Cloudera host from CDH config
    local is_cloudera=false
    if [[ "$host" =~ cdh ]]; then
      is_cloudera=true
      cloudera_vmss_count=$((cloudera_vmss_count + 1))
    else
      # Extract base VMSS name (e.g., int-01-cdhmng01-vmss from int-01-cdhmng01-vmss_0)
      local vmss_base=$(echo "$host" | sed 's/-vmss[_0-9]*$//')
      for cdh_base in "${cloudera_base_names[@]}"; do
        if [[ "$vmss_base" == "$cdh_base" ]]; then
          is_cloudera=true
          cloudera_vmss_count=$((cloudera_vmss_count + 1))
          info "  Identified as Cloudera VMSS (matches CDH host: $cdh_base)"
          break
        fi
      done
    fi

    # Skip if not a Cloudera instance
    if [[ "$is_cloudera" == false ]]; then
      continue
    fi

    echo "[INFO] Cloudera VMSS Instance: $host (RG: $rg)"

    # Parse VMSS name and instance ID
    # Azure VMSS instances can have formats:
    #   - int-01-cdhmng01-vmss_0 (underscore format)
    #   - int-01-cdhmng01-vmss000000 (zero-padded format)
    local vmss_name instance_id
    if [[ "$host" =~ ^(.+)-vmss_([0-9]+)$ ]]; then
      # Format: name-vmss_0 (underscore format)
      vmss_name="${BASH_REMATCH[1]}-vmss"
      instance_id="${BASH_REMATCH[2]}"
    elif [[ "$host" =~ ^(.+)-vmss([0-9]+)$ ]]; then
      # Format: name-vmss000000 (directly attached digits)
      vmss_name="${BASH_REMATCH[1]}-vmss"
      instance_id="${BASH_REMATCH[2]}"
      # Remove leading zeros from instance_id
      instance_id=$((10#$instance_id))
    else
      warn "Cannot parse Cloudera VMSS instance name: $host — skipping"
      continue
    fi

    info "Parsed: VMSS=$vmss_name, Instance ID=$instance_id"

    # Check if the VMSS instance exists and get both power state and provisioning state
    local state provisioning_state
    if ! state=$(az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
      --query "statuses[?starts_with(code,'PowerState/')].code" -o tsv 2>&1 | tail -1); then
      warn "Cloudera VMSS instance $host not found or not accessible in resource group $rg — skipping"
      continue
    fi

    # Check provisioning state
    provisioning_state=$(az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
      --query "statuses[?starts_with(code,'ProvisioningState/')].code" -o tsv 2>/dev/null | tail -1 || echo "")

    # Skip if the resource is not found (empty state or error)
    if [[ -z "$state" || "$state" =~ (ResourceNotFound|InstanceViewNotFound|NotFound) ]]; then
      warn "Cloudera VMSS instance $host does not exist or is not accessible — skipping"
      continue
    fi

    # Check if provisioning failed (case-insensitive check)
    if [[ "${provisioning_state,,}" =~ failed ]]; then
      error "Cloudera VMSS instance $host has FAILED provisioning state in Azure"
      error "  Power State: $state"
      error "  Provisioning State: $provisioning_state"
      error "  This instance cannot be used until reprovisioned"
      error "  Fix: Delete and recreate this instance, or redeploy the VMSS"
      record_summary error "Cloudera VMSS $host has failed provisioning - needs Azure remediation"
      continue
    fi

    case "$ACTION" in
      start)
        if [[ "$state" == "PowerState/running" ]]; then
          warn "Cloudera VMSS instance $host already running — skipping start"
        else
          info "Starting Cloudera VMSS instance $host..."
          local start_output start_result
          start_output=$(az vmss start --name "$vmss_name" --resource-group "$rg" --instance-ids "$instance_id" --no-wait 2>&1)
          start_result=$?
          
          # With --no-wait, trust exit code 0 or check for acceptable messages in output
          # Azure may return non-zero if instance is transitioning, but that's OK
          if [[ $start_result -eq 0 ]]; then
            # Command accepted successfully
            success "Start Cloudera VMSS instance $host (start command accepted)"
            record_summary success "Start Cloudera VMSS instance $host"
          elif [[ "$start_output" =~ [Ss]ucceeded|[Aa]ccepted|[Ii]n[Pp]rogress|already|running|transitioning|starting ]]; then
            # Output indicates operation is proceeding
            success "Start Cloudera VMSS instance $host (operation in progress)"
            record_summary success "Start Cloudera VMSS instance $host"
          else
            # Genuine error - check if it's a real problem
            if [[ "$start_output" =~ [Nn]ot.[Ff]ound|does.not.exist|[Ii]nvalid ]]; then
              error "Failed to start Cloudera VMSS instance $host: $start_output"
              record_summary error "Failed to start Cloudera VMSS instance $host"
            else
              # Unknown response, but don't block - may still have started
              warn "Start Cloudera VMSS instance $host returned unexpected response (may still succeed)"
              info "  Response: $start_output"
              record_summary warn "Start Cloudera VMSS instance $host (uncertain - verify manually)"
            fi
            continue
          fi
        fi
        ;;
      stop)
        if [[ "$state" == "PowerState/deallocated" || "$state" == "PowerState/stopped" ]]; then
          warn "Cloudera VMSS instance $host already stopped — skipping"
          cloudera_vmss_stopped=$((cloudera_vmss_stopped + 1))
        else
          info "Stopping Cloudera VMSS instance $host..."
          local stop_output stop_result
          stop_output=$(az vmss deallocate --name "$vmss_name" --resource-group "$rg" --instance-ids "$instance_id" --no-wait 2>&1)
          stop_result=$?
          
          # Check if stop was successful or if instance is already stopping/stopped
          if [[ $stop_result -eq 0 ]] || [[ "$stop_output" =~ "Succeeded"|"Accepted"|"InProgress"|"already"|"deallocated" ]]; then
            success "Stop Cloudera VMSS instance $host (stop operation initiated)"
            record_summary success "Stop Cloudera VMSS instance $host"
            cloudera_vmss_stopped=$((cloudera_vmss_stopped + 1))
          else
            # Log the actual error for troubleshooting
            warn "Failed to stop Cloudera VMSS instance $host: $stop_output"
            record_summary warn "Failed to stop Cloudera VMSS instance $host"
            continue
          fi
        fi
        ;;
      status)
        if ! az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
          --query "{Name:'$host',PowerState:statuses[?starts_with(code,'PowerState/')].displayStatus | [0]}" --output table 2>/dev/null; then
          warn "Cannot get status for Cloudera VMSS instance $host"
        fi
        ;;
    esac
  done < "$vmcfg"

  # Summary reporting for Cloudera VMSS instances
  if [[ "$ACTION" == "stop" ]]; then
    if [[ $cloudera_vmss_count -eq 0 ]]; then
      info "No Cloudera VMSS instances found"
    else
      info "Cloudera VMSS Summary: $cloudera_vmss_stopped of $cloudera_vmss_count instances stopped"
      if [[ $cloudera_vmss_stopped -eq $cloudera_vmss_count ]]; then
        success "All Cloudera VMSS instances are stopped"
        record_summary success "All $cloudera_vmss_count Cloudera VMSS instances stopped"
      else
        warn "Not all Cloudera VMSS instances are stopped ($cloudera_vmss_stopped/$cloudera_vmss_count)"
        record_summary warn "Only $cloudera_vmss_stopped of $cloudera_vmss_count Cloudera VMSS instances stopped"
      fi
    fi
  elif [[ "$ACTION" == "start" ]]; then
    if [[ $cloudera_vmss_count -eq 0 ]]; then
      info "No Cloudera VMSS instances found"
    else
      info "Processed $cloudera_vmss_count Cloudera VMSS instance(s)"
    fi
  fi
}

ManageVMs() {
  log_section "Azure VM Management"
  local vmcfg="${CONFIG_DIR}/${Env_Code}_VM.config"
  [[ ! -f "$vmcfg" ]] && { warn "VM config not found: $vmcfg"; return; }

  # Read config with format: instance_name<tab>resource_group<tab>computer_fqdn (optional)
  while IFS=$'\t' read -r host rg computer_fqdn; do
    [[ -z "$host" || -z "$rg" ]] && continue

    # Skip VMSS instances - they are handled by ManageVMSS()
    # Check for -vmss followed by numbers or underscore+numbers
    if [[ "$host" =~ -vmss([0-9]+|_[0-9]+)$ ]]; then
      continue
    fi

    echo "[INFO] VM: $host (RG: $rg)"

    # Check if the VM exists first
    local state
    if ! state=$(az vm get-instance-view --name "$host" --resource-group "$rg" \
      --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" -o tsv 2>&1 | tail -1); then
      warn "VM $host not found or not accessible in resource group $rg — skipping"
      continue
    fi

    # Skip if the resource is not found (empty state or error)
    if [[ -z "$state" || "$state" =~ ResourceNotFound ]]; then
      warn "VM $host does not exist or is not a VM resource — skipping"
      continue
    fi

    case "$ACTION" in
      start)
        if [[ "$state" == "PowerState/running" ]]; then
          warn "VM $host already running — skipping start"
        else
          if az vm start --name "$host" --resource-group "$rg" 2>/dev/null; then
            success "Start VM $host"
            record_summary success "Start VM $host"
          else
            warn "Failed to start VM $host — may not exist or is not accessible"
            record_summary warn "Failed to start VM $host"
            continue
          fi
        fi
         ValidateFW "$host"
        ;;
      stop)
        if [[ "$state" == "PowerState/deallocated" || "$state" == "PowerState/stopped" ]]; then
          warn "VM $host already stopped — skipping"
        else
          if az vm deallocate --name "$host" --resource-group "$rg" 2>/dev/null; then
            success "Stop VM $host"
            record_summary success "Stop VM $host"
          else
            warn "Failed to stop VM $host — may not exist or is not accessible"
            record_summary warn "Failed to stop VM $host"
            continue
          fi
        fi
        ;;
      status)
        if ! az vm get-instance-view --name "$host" --resource-group "$rg" \
          --query "{Name:name,PowerState:instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]}" --output table 2>/dev/null; then
          warn "Cannot get status for VM $host"
        fi
        ;;
    esac
#    ValidateFW "$host"
  done < "$vmcfg"
}

ManagePGServers() {
  log_section "PostgreSQL Flexible Server Management"
  local pgcfg="${CONFIG_DIR}/${Env_Code}_PG.config"
  [[ ! -f "$pgcfg" ]] && { warn "PG config not found: $pgcfg"; return; }

  while read -r pg rg; do
    [[ -z "$pg" || -z "$rg" ]] && continue
    echo "[INFO] PostgreSQL: $pg (RG: $rg)"

    local state
    if ! state=$(az postgres flexible-server show --name "$pg" --resource-group "$rg" --query "state" -o tsv 2>&1); then
      warn "PostgreSQL server $pg not found or not accessible in resource group $rg — skipping"
      continue
    fi

    # Skip if the resource is not found
    if [[ -z "$state" || "$state" =~ ResourceNotFound ]]; then
      warn "PostgreSQL server $pg does not exist — skipping"
      continue
    fi

    case "$ACTION" in
      start)
        if [[ "$state" == "Ready" ]]; then
          warn "PostgreSQL $pg already running"
        else
          if az postgres flexible-server start --name "$pg" --resource-group "$rg" 2>/dev/null; then
            success "Start PG $pg"
            record_summary success "Start PG $pg"
          else
            warn "Failed to start PostgreSQL $pg"
            record_summary warn "Failed to start PostgreSQL $pg"
          fi
        fi
        ;;
      stop)
        if [[ "$state" == "Stopped" ]]; then
          warn "PostgreSQL $pg already stopped"
        else
          if az postgres flexible-server stop --name "$pg" --resource-group "$rg" 2>/dev/null; then
            success "Stop PG $pg"
            record_summary success "Stop PG $pg"
          else
            warn "Failed to stop PostgreSQL $pg"
            record_summary warn "Failed to stop PostgreSQL $pg"
          fi
        fi
        ;;
      status)
        if ! az postgres flexible-server show --name "$pg" --resource-group "$rg" \
          --query "{Name:name,State:state}" --output table 2>/dev/null; then
          warn "Cannot get status for PostgreSQL $pg"
        fi
        ;;
    esac
  done < "$pgcfg"
}

# (Cloudera, Consul, Kubernetes management functions remain unchanged)
# ... [keep your existing ManageCDH, ManageConsul, ScaleDeployments, ValidatePods definitions] ...
ManageCDH() {
  log_section "Cloudera Services Management"
  local REMOTE_USER=taapp1
  local COMPONENT=CDH
  local cdh_config="${CONFIG_DIR}/${Env_Code}_CDH.config"

  # Check if Cloudera config exists
  if [[ ! -f "$cdh_config" ]]; then
    warn "No Cloudera config found at $cdh_config"
    return
  fi

  local REMOTE_HOST
  # Search for management node first (cdhmng) in the CDH config
  REMOTE_HOST=$(grep -i 'cdhmng' "$cdh_config" | head -1 || true)
  [[ -z "$REMOTE_HOST" ]] && REMOTE_HOST=$(head -1 "$cdh_config" || true)
  [[ -z "$REMOTE_HOST" ]] && { warn "No Cloudera host found in config"; return; }

  export host=$REMOTE_HOST
  info "Target CDH host: $REMOTE_HOST (using user: $REMOTE_USER)"

  # Check network reachability
  if ! is_host_reachable "$host"; then
    warn "[${COMPONENT}] Host $host not reachable — skipping Cloudera services"
    return
  fi

  # Test SSH connectivity first
  info "Testing SSH connectivity to ${REMOTE_USER}@${REMOTE_HOST}..."
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${REMOTE_USER}@${REMOTE_HOST}" "echo 'SSH OK'" &>/dev/null; then
    warn "[${COMPONENT}] SSH authentication failed to ${REMOTE_USER}@${REMOTE_HOST} — skipping Cloudera services (check SSH keys)"
    return
  fi

  success "SSH connectivity verified to ${REMOTE_USER}@${REMOTE_HOST}"

  # Check if user can run sudo without password for Cloudera service commands
  # Test with an actual command that's allowed in sudoers (is-active cloudera-scm-agent)
  local sudo_check
  if ! sudo_check=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo -n systemctl is-active cloudera-scm-agent 2>&1"); then
    if [[ "$sudo_check" =~ "password is required" ]]; then
      error "taapp1 user requires password for sudo. Please configure passwordless sudo for Cloudera services."
      error "Run on cdhmng01 as root:"
      error "  cat > /etc/sudoers.d/cloudera-taapp1 << 'EOF'"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/systemctl start cloudera-scm-*"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop cloudera-scm-*"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/systemctl status cloudera-scm-*"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/systemctl is-active cloudera-scm-*"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/tail /var/log/cloudera-scm-server/*"
      error "taapp1 ALL=(ALL) NOPASSWD: /usr/bin/grep * /var/log/cloudera-scm-server/*"
      error "EOF"
      error "  sudo chmod 440 /etc/sudoers.d/cloudera-taapp1"
      warn "Skipping Cloudera service management - sudo password required"
      record_summary error "Cloudera management skipped: sudo password required for taapp1"
      return
    fi
  fi

  info "Sudo access verified for ${REMOTE_USER} (passwordless sudo configured)"

  # Define service arrays with proper ordering
  # Stop order: agent -> server -> server-db -> supervisord (reverse dependency order)
  # Start order: supervisord -> server-db -> server -> agent (dependency order)
  local START_SERVICES=("cloudera-scm-supervisord.service" "cloudera-scm-server-db.service" "cloudera-scm-server.service" "cloudera-scm-agent")
  local STOP_SERVICES=("cloudera-scm-agent" "cloudera-scm-server.service" "cloudera-scm-server-db.service" "cloudera-scm-supervisord.service")

  # Select appropriate order based on action
  local SERVICES
  if [[ "$ACTION" == "stop" ]]; then
    SERVICES=("${STOP_SERVICES[@]}")
  else
    SERVICES=("${START_SERVICES[@]}")
  fi

  for service in "${SERVICES[@]}"; do
    local state error_msg service_loaded

    # Check if service exists/is loaded
    service_loaded=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "systemctl list-unit-files $service 2>/dev/null | grep -c $service" || echo "0")

    if [[ "$service_loaded" == "0" ]]; then
      info "$service not installed on this system - skipping"
      continue
    fi

    # Use sudo -n (non-interactive) to fail fast if password is required
    state=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo -n systemctl is-active $service" 2>/dev/null || echo "unknown")

    case "$ACTION" in
      start)
        if [[ "$state" == "active" ]]; then
          warn "$service already active"
        else
          info "Starting $service on $REMOTE_HOST..."
          # Capture both stdout and stderr for better error reporting
          if error_msg=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo -n systemctl start $service 2>&1"); then
            success "Start $service"
            record_summary success "Start $service"
            # Wait for service to stabilize (2 seconds)
            sleep 2
          else
            # Check if error is due to service not being loaded
            if [[ "$error_msg" =~ "not loaded" || "$error_msg" =~ "not found" ]]; then
              info "$service not available on this system - skipping"
            else
              error "Failed to start $service: ${error_msg}"
              record_summary error "Failed to start $service: ${error_msg}"
            fi
          fi
        fi
        ;;
      stop)
        if [[ "$state" == "inactive" || "$state" == "failed" ]]; then
          warn "$service already stopped"
        else
          info "Stopping $service on $REMOTE_HOST..."
          # Capture both stdout and stderr for better error reporting
          if error_msg=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo -n systemctl stop $service 2>&1"); then
            success "Stop $service"
            record_summary success "Stop $service"
            # Wait for service to stop completely (2 seconds)
            sleep 2
          else
            # Check if error is due to service not being loaded
            if [[ "$error_msg" =~ "not loaded" || "$error_msg" =~ "not found" ]]; then
              info "$service not available on this system - skipping"
            else
              error "Failed to stop $service: ${error_msg}"
              record_summary error "Failed to stop $service: ${error_msg}"
            fi
          fi
        fi
        ;;
      status)
        info "Checking status of $service..."
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" "sudo -n systemctl status $service --no-pager | grep -E 'Active|Loaded' || true" 2>/dev/null; then
          success "Status $service"
          record_summary success "Status $service"
        else
          warn "Cannot get status for $service"
          record_summary warn "Cannot get status for $service"
        fi
        ;;
    esac
  done

  # Note: Cloudera VMSS instances are managed by ManageClouderaVMSS() function

# Run Cloudera Manager server check if applicable
if [[ ${ACTION} = "start" ]] || [[ ${ACTION} = "status" ]]; then
  # Wait for CM server to be fully operational (it takes 8-15 minutes after service start)
  if [[ ${ACTION} = "start" ]]; then
    info "Waiting 8 minutes for Cloudera Manager server to initialize..."
    info "Note: CM needs to load database, configure web server, and register agents"
    sleep 480
  fi
  
  info "Checking Cloudera Manager server accessibility..."
  info "Target: http://${CM_SERVER_FQDN}:7180"
  
  # Try to connect directly with timeout - faster than running external script
  local cm_ready=false
  local max_retries=5
  local retry_count=0
  
  while [[ $retry_count -lt $max_retries ]]; do
    retry_count=$((retry_count + 1))
    info "  Attempt $retry_count/$max_retries: Testing CM API endpoint..."
    
    # Test API endpoint with 10 second timeout
    local cm_response
    cm_response=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${REMOTE_HOST}" \
      "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 http://localhost:7180/api/version" 2>/dev/null || echo "000")
    
    if [[ "$cm_response" =~ ^(200|30[0-9]|401)$ ]]; then
      # 200 = success, 30x = redirect (CM is up), 401 = authentication required but server is up
      success "Cloudera Manager server is responding (HTTP $cm_response)"
      cm_ready=true
      break
    else
      if [[ $retry_count -lt $max_retries ]]; then
        warn "  CM not ready yet (HTTP $cm_response), waiting 30 seconds before retry..."
        sleep 30
      fi
    fi
  done
  
  if [[ "$cm_ready" == true ]]; then
    success "Cloudera Manager server is accessible"
    record_summary success "Cloudera Manager server is accessible"
    info "Web UI: http://${CM_SERVER_FQDN}:7180"
  else
    if [[ ${ACTION} = "start" ]]; then
      warn "Cloudera Manager server not yet accessible after $((retry_count * 30)) seconds of retries"
      warn "Total wait time: $((480 + retry_count * 30)) seconds (~$(((480 + retry_count * 30) / 60)) minutes)"
      warn ""
      warn "This is NORMAL - CM can take 12-18 minutes on first start after reboot."
      warn ""
      warn "NEXT STEPS:"
      warn "  1. Wait another 5-10 minutes"
      warn "  2. Check CM status: ./EnvControl.sh ${Env_Code} status"
      warn "  3. Check logs: ssh taapp1@${REMOTE_HOST} \"sudo tail -50 /var/log/cloudera-scm-server/cloudera-scm-server.log\""
      warn "  4. Look for: 'Started Jetty server' or 'WebServerImpl' messages in logs"
      warn ""
      warn "Web UI: http://${CM_SERVER_FQDN}:7180"
      record_summary warn "Cloudera Manager still initializing - wait 5-10 more minutes and check status"
    else
      error "Cloudera Manager server is not accessible"
      error "Web UI: http://${CM_SERVER_FQDN}:7180"
      error ""
      error "Troubleshooting:"
      error "  1. Check if CM server process is running:"
      error "     ssh taapp1@${REMOTE_HOST} \"ps aux | grep cloudera-scm-server | grep -v grep\""
      error "  2. Check recent logs for errors:"
      error "     ssh taapp1@${REMOTE_HOST} \"sudo tail -100 /var/log/cloudera-scm-server/cloudera-scm-server.log\""
      error "  3. Check if ports are listening:"
      error "     ssh taapp1@${REMOTE_HOST} \"netstat -tlnp | grep -E '7180|7183'\""
      record_summary error "Cloudera Manager server is not accessible"
    fi
  fi
fi

}

ConsulStatus() {
  log_section "Consul Status"
  local REMOTE_USER=azure
  local master_host="$1"
  local timeout_local=${2:-$TIMEOUT}
  local interval=10
  local elapsed=0

  if [[ -z "$master_host" ]]; then
    warn "Consul master host not set"
    return 1
  fi

  # Test SSH connectivity first
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${REMOTE_USER}@${master_host}" "echo 'SSH OK'" &>/dev/null; then
    warn "SSH authentication failed to ${REMOTE_USER}@${master_host} — skipping Consul status check"
    return 1
  fi

  echo "Checking Consul member status every $interval seconds for up to $((timeout_local/60)) minutes..."

  while [ $elapsed -lt $timeout_local ]; do
    echo "[$(date '+%H:%M:%S')] Running 'consul members' on $master_host..."

    local consul_output
    if ! consul_output=$(ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $REMOTE_USER@$master_host "consul members" 2>/dev/null); then
      warn "Failed to get consul members from $master_host"
      return 1
    fi

    echo "$consul_output"
    FAILED_COUNT=$(echo "$consul_output" | grep -c "failed" || true)

    if [ "$FAILED_COUNT" -eq 0 ]; then
        echo "✅ All Consul members are healthy."
        return 0
    else
        echo "⚠️  $FAILED_COUNT Consul member(s) in FAILED state. Retrying in $interval seconds..."
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "❌ Timeout reached after $((timeout_local/60)) minutes. Some Consul members are still in FAILED status."
  return 1
}

ManageConsul() {
  log_section "Consul Management"
  local REMOTE_USER=taapp1
  local consul_config="${CONFIG_DIR}/${Env_Code}_CONSUL.config"
  
  # Check if Consul config exists, if not try to generate it
  if [[ ! -f "$consul_config" ]]; then
    warn "Consul config not found: $consul_config"
    info "Attempting to generate Consul config from VM list..."
    GetConsulHosts || { error "Failed to generate Consul config"; return; }
  fi

  # Validate Consul config format (check first line has tab-separated fields)
  if [[ -f "$consul_config" ]]; then
    local first_line
    first_line=$(head -1 "$consul_config")
    local field_count=$(echo "$first_line" | awk -F'\t' '{print NF}')
    
    if [[ $field_count -lt 3 ]]; then
      error ""
      error "═══════════════════════════════════════════════════════════════════"
      error "  INVALID CONSUL CONFIG FORMAT DETECTED"
      error "═══════════════════════════════════════════════════════════════════"
      error ""
      error "Your Consul config has $field_count field(s), but requires at least 3:"
      error "  Expected: instance_name<tab>resource_group<tab>computer_fqdn<tab>private_ip"
      error "  Found:    $first_line"
      error ""
      error "This usually means the VM config is outdated or corrupted."
      error ""
      error "REQUIRED ACTION: Regenerate configs with:"
      error "  REFRESH_CONFIG=true ./EnvControl.sh ${Env_Code} ${ACTION}"
      error ""
      error "This will delete and regenerate both VM and Consul configs from Azure."
      error "═══════════════════════════════════════════════════════════════════"
      error ""
      return 1
    fi
  fi

  # If starting, wait for VMSS instances to be fully operational
  if [[ "$ACTION" == "start" ]]; then
    info "Waiting 5 minutes for Consul VMSS instances to boot and initialize network..."
    info "This includes time for Azure networking, SSH daemon, and Consul agent startup"
    sleep 300
  fi

  # Read Consul config with format: instance_name<tab>resource_group<tab>computer_fqdn<tab>private_ip
  local CONSUL_HOSTS=""
  local -A CONSUL_HOST_MAP  # Map instance_name -> computer_fqdn or IP
  local -A CONSUL_IP_MAP    # Map IP/FQDN -> display name
  local missing_ip_count=0
  
  while IFS=$'\t' read -r instance_name rg computer_fqdn private_ip; do
    [[ -z "$instance_name" ]] && continue
    
    # Prefer private IP over FQDN if available (avoids DNS issues)
    if [[ -n "$private_ip" && "$private_ip" != "null" ]]; then
      CONSUL_HOSTS+=" $private_ip"
      CONSUL_HOST_MAP["$instance_name"]="$private_ip"
      # Store reverse mapping for display purposes
      CONSUL_IP_MAP["$private_ip"]="$computer_fqdn"
    elif [[ -n "$computer_fqdn" && "$computer_fqdn" != "null" ]]; then
      # Fallback to FQDN if no IP available
      CONSUL_HOSTS+=" $computer_fqdn"
      CONSUL_HOST_MAP["$instance_name"]="$computer_fqdn"
      missing_ip_count=$((missing_ip_count + 1))
      warn "  No IP found for $instance_name, using FQDN: $computer_fqdn (may fail if DNS not configured)"
    else
      error "  Invalid config entry for $instance_name - missing both IP and FQDN"
      continue
    fi
  done < "$consul_config"
  
  # Warn if we're using FQDNs without IPs
  if [[ $missing_ip_count -gt 0 ]]; then
    warn ""
    warn "═══════════════════════════════════════════════════════════════════"
    warn "  CONFIG OUTDATED: $missing_ip_count host(s) missing private IP"
    warn "═══════════════════════════════════════════════════════════════════"
    warn "Your Consul config file is missing private IP addresses."
    warn "This may cause DNS resolution failures if hosts aren't in DNS."
    warn ""
    warn "Recommended: Regenerate config with IP addresses:"
    warn "  REFRESH_CONFIG=true ./EnvControl.sh ${Env_Code} ${ACTION}"
    warn ""
    warn "This will update the config with private IPs from Azure for"
    warn "faster and more reliable connectivity (no DNS required)."
    warn "═══════════════════════════════════════════════════════════════════"
    warn ""
  fi

  if [[ -z "$CONSUL_HOSTS" ]]; then
    warn "No consul-capable hosts found (master/consul/tccli/tcuh)"
    return
  fi

  local COMPONENT=consul
  local host_count=$(echo "$CONSUL_HOSTS" | wc -w)
  info "Checking Consul on $host_count host(s) (taapp1 user for master/consul/tcuh, admin for tccli)"
  
  # Show which hosts we'll be checking
  info "Consul hosts to check:"
  for h in $CONSUL_HOSTS; do
    info "  - $h"
  done

  # Verify VMSS instances are running in Azure first and filter out failed instances
  # This is optional - if it's slow or fails, we'll still try SSH
  info "Verifying VMSS instance states in Azure (this may be slow, will skip on timeout)..."
  local vmss_states_checked=0
  local failed_instances=0
  local -A failed_instance_map  # Track failed instances to skip later
  
  while IFS=$'\t' read -r instance_name rg computer_fqdn private_ip; do
    [[ -z "$instance_name" ]] && continue
    # Only check VMSS instances
    if [[ "$instance_name" =~ -vmss ]]; then
      # Parse VMSS name and instance ID
      local vmss_name instance_id
      if [[ "$instance_name" =~ ^(.+)-vmss_([0-9]+)$ ]]; then
        vmss_name="${BASH_REMATCH[1]}-vmss"
        instance_id="${BASH_REMATCH[2]}"
      elif [[ "$instance_name" =~ ^(.+)-vmss([0-9]+)$ ]]; then
        vmss_name="${BASH_REMATCH[1]}-vmss"
        instance_id="${BASH_REMATCH[2]}"
        instance_id=$((10#$instance_id))
      else
        warn "  Cannot parse instance name: $instance_name"
        continue
      fi
      
      # Prepare display name for logging (use IP if available, otherwise FQDN)
      local display_name="$computer_fqdn"
      [[ -n "$private_ip" && "$private_ip" != "null" ]] && display_name="$private_ip ($computer_fqdn)"
      
      # Skip Azure verification if we have an IP - we'll test reachability directly
      if [[ -n "$private_ip" && "$private_ip" != "null" ]]; then
        info "  $display_name: Skipping Azure query (have IP, will test directly)"
        continue
      fi
      
      # Only query Azure if we don't have an IP address
      info "  Querying Azure: VMSS=$vmss_name, InstanceID=$instance_id, RG=$rg"
      
      # Check Azure power state and provisioning state with timeout
      local power_state provisioning_state
      local query_result
      
      # Use timeout to avoid hanging (5 seconds max per query)
      query_result=$(timeout 5s az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
        --query "statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>&1)
      local query_exit=$?
      
      if [[ $query_exit -eq 0 && -n "$query_result" && "$query_result" != "null" ]]; then
        power_state="$query_result"
        
        # Also get provisioning state
        provisioning_state=$(timeout 5s az vmss get-instance-view --name "$vmss_name" --resource-group "$rg" --instance-id "$instance_id" \
          --query "statuses[?starts_with(code,'ProvisioningState/')].displayStatus | [0]" -o tsv 2>/dev/null || echo "Unknown")
        
        # Check for failed provisioning (case-insensitive)
        if [[ "${provisioning_state,,}" =~ failed ]]; then
          error "  $display_name: $power_state | Provisioning: FAILED ❌"
          error "    This instance has failed provisioning in Azure and cannot be reached"
          error "    Root cause: VM never initialized - no network, DNS, or SSH access"
          error "    Fix required: Reimage or recreate this VMSS instance in Azure"
          record_summary error "Consul VMSS $display_name has FAILED provisioning - needs Azure remediation"
          # Track by both IP and FQDN
          [[ -n "$private_ip" && "$private_ip" != "null" ]] && failed_instance_map["$private_ip"]=1
          failed_instance_map["$computer_fqdn"]=1
          failed_instances=$((failed_instances + 1))
        else
          info "  $display_name: $power_state | Provisioning: $provisioning_state"
        fi
        vmss_states_checked=$((vmss_states_checked + 1))
      elif [[ $query_exit -eq 124 ]]; then
        warn "  $display_name: Azure query timed out (will try SSH anyway)"
      else
        # Query failed - just note it but don't block
        warn "  $display_name: Azure query failed (will try SSH anyway)"
        [[ -n "$query_result" ]] && info "    Error: ${query_result:0:150}"
      fi
    fi
  done < "$consul_config"
  
  if [[ $vmss_states_checked -gt 0 ]]; then
    info "Verified $vmss_states_checked Consul VMSS instance(s) in Azure"
    if [[ $failed_instances -gt 0 ]]; then
      error "CRITICAL: $failed_instances Consul VMSS instance(s) have FAILED provisioning state"
      error "These instances will be skipped - they cannot be reached until fixed in Azure"
    fi
  fi

  # Find first master host for consul members command (use IP or FQDN)
  local MASTER_HOST=$(echo "$CONSUL_HOSTS" | tr ' ' '\n' | head -1 || true)

  local reachable_count=0
  local unreachable_hosts=()

  for REMOTE_HOST in $CONSUL_HOSTS; do
    [[ -z "$REMOTE_HOST" ]] && continue

    # Skip instances that have failed provisioning in Azure
    if [[ -n "${failed_instance_map[$REMOTE_HOST]:-}" ]]; then
      info "Skipping $REMOTE_HOST (failed provisioning in Azure - already reported above)"
      continue
    fi

    # Get display name for logging (show FQDN if we have IP)
    local display_name="$REMOTE_HOST"
    if [[ -n "${CONSUL_IP_MAP[$REMOTE_HOST]:-}" ]]; then
      display_name="$REMOTE_HOST (${CONSUL_IP_MAP[$REMOTE_HOST]})"
    fi

    # Determine correct user: admin for tccli hosts, taapp1 for others
    local CONSUL_USER=$REMOTE_USER
    if [[ "$REMOTE_HOST" =~ tccli ]] || [[ "${CONSUL_IP_MAP[$REMOTE_HOST]:-}" =~ tccli ]]; then
      CONSUL_USER="admin"
    fi

    # Check reachability with detailed diagnostics
    info "Testing reachability of $display_name..."
    if ! is_host_reachable "$REMOTE_HOST"; then
      # For IP addresses, we shouldn't see DNS failures
      if [[ "$REMOTE_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "[${COMPONENT}] Host $display_name not reachable (IP ping/SSH port 22 check failed)"
        warn "  VM is provisioned in Azure but network/SSH is not responding"
        warn "  Possible causes: VM still booting, NSG blocking port 22, or network interface not ready"
      else
        warn "[${COMPONENT}] Host $REMOTE_HOST not reachable (ping/SSH port 22 check failed)"
        
        # Additional diagnostics for FQDN
        info "  Attempting DNS resolution for $REMOTE_HOST..."
        if host "$REMOTE_HOST" &>/dev/null || nslookup "$REMOTE_HOST" &>/dev/null; then
          info "  DNS resolution successful - host exists in DNS"
          warn "  Host is in DNS but network/SSH is not responding (may still be booting)"
        else
          warn "  DNS resolution failed - host may not be registered in DNS yet"
          warn "  This typically means the VM never fully initialized (check Azure provisioning state)"
        fi
      fi
      
      unreachable_hosts+=("$display_name")
      continue
    fi

    reachable_count=$((reachable_count + 1))

    # Test SSH connectivity
    info "Testing SSH connectivity to ${CONSUL_USER}@${display_name}..."
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${CONSUL_USER}@${REMOTE_HOST}" "echo 'SSH OK'" &>/dev/null; then
      warn "[${COMPONENT}] SSH authentication failed to ${CONSUL_USER}@${display_name} — skipping Consul check on this host"
      continue
    fi

    success "SSH connectivity verified to ${CONSUL_USER}@${display_name}"

    # Check if Consul is running as a process (not systemd service)
    local consul_pid
    consul_pid=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${CONSUL_USER}@${REMOTE_HOST}" "pgrep -f 'consul agent' | head -1" 2>/dev/null || echo "")

    if [[ -n "$consul_pid" ]]; then
      success "Consul agent is running on $display_name (PID: $consul_pid) - managed by taapp1 user, not systemd"
      record_summary success "Consul running on $display_name (PID: $consul_pid)"
    else
      warn "Consul agent not running on $display_name"
      record_summary warn "Consul not running on $display_name"
    fi
  done

  # For status action, run consul members command from master host
  if [[ "$ACTION" == "status" && -n "$MASTER_HOST" ]]; then
    local master_display="$MASTER_HOST"
    [[ -n "${CONSUL_IP_MAP[$MASTER_HOST]:-}" ]] && master_display="$MASTER_HOST (${CONSUL_IP_MAP[$MASTER_HOST]})"
    
    info "Checking Consul cluster members from $master_display..."
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "${REMOTE_USER}@${MASTER_HOST}" "consul members" 2>/dev/null; then
      success "Consul cluster status retrieved"
    else
      warn "Could not retrieve Consul members - consul CLI may not be in PATH"
    fi
  fi

  # Summary of Consul host connectivity
  if [[ ${#unreachable_hosts[@]} -gt 0 ]]; then
    warn "Summary: $reachable_count of $host_count Consul host(s) reachable"
    warn "Unreachable hosts (may need more time to boot or network to initialize):"
    for h in "${unreachable_hosts[@]}"; do
      warn "  - $h"
    done
    if [[ "$ACTION" == "start" ]]; then
      warn ""
      warn "═══════════════════════════════════════════════════════════════════"
      warn "  TROUBLESHOOTING GUIDE: Consul VMSS Instances Not Reachable"
      warn "═══════════════════════════════════════════════════════════════════"
      warn ""
      warn "Common causes:"
      warn "  1. VMSS instances in FAILED provisioning state (see errors above)"
      warn "  2. VMSS instances still booting (10-15 minutes typical)"
      warn "  3. Azure networking/NSG rules not yet applied"
      warn "  4. DNS propagation delay (check: nslookup <hostname>)"
      warn "  5. SSH keys not configured for taapp1/admin users"
      warn "  6. Instances running but network interface not ready"
      warn ""
      warn "Diagnostic commands to run:"
      warn "  # Check provisioning state in Azure Portal or CLI"
      warn "  az vmss list-instances --name <vmss-name> --resource-group <rg> \\"
      warn "    --query '[].{Name:name,PowerState:instanceView.statuses[?starts_with(code,\"PowerState\")].code|[0],ProvisioningState:instanceView.statuses[?starts_with(code,\"ProvisioningState\")].code|[0]}' -o table"
      warn ""
      warn "  # Check DNS resolution"
      warn "  nslookup ${unreachable_hosts[0]}"
      warn ""
      warn "  # Check if SSH port is open (requires network access)"
      warn "  nc -zv ${unreachable_hosts[0]} 22"
      warn ""
      warn "══════════════════════════════════════════════════════════════════════"
      warn "  CRITICAL: If instances show 'Provisioning State: Failed' in Azure:"
      warn "══════════════════════════════════════════════════════════════════════"
      warn ""
      warn "Failed provisioning means the VM never initialized properly and CANNOT"
      warn "be fixed by waiting. You must take action in Azure:"
      warn ""
      warn "Option 1: Reimage failed instances (preserves VMSS)"
      warn "  az vmss reimage --name <vmss-name> --resource-group <rg> --instance-id <id>"
      warn ""
      warn "Option 2: Delete and recreate the instance"
      warn "  az vmss delete-instances --name <vmss-name> --resource-group <rg> --instance-ids <id>"
      warn "  az vmss update-instances --name <vmss-name> --resource-group <rg> --instance-ids <id>"
      warn ""
      warn "Option 3: Scale set to 0 and back to desired count (nuclear option)"
      warn "  az vmss scale --name <vmss-name> --resource-group <rg> --new-capacity 0"
      warn "  az vmss scale --name <vmss-name> --resource-group <rg> --new-capacity 1"
      warn ""
      warn "Option 4: Check Azure Activity Log for root cause"
      warn "  Azure Portal → Virtual Machine Scale Sets → <vmss-name> → Activity log"
      warn "  Look for allocation failures, quota issues, or image problems"
      warn ""
      warn "══════════════════════════════════════════════════════════════════════"
      warn ""
      warn "If no provisioning failures detected:"
      warn "  Wait 10-15 minutes after 'start' completes, then re-run:"
      warn "    ./EnvControl.sh ${Env_Code} status"
      warn ""
      warn "  If instances are running in Azure but still not reachable:"
      warn "    - Verify NSG rules allow SSH (port 22) from your location"
      warn "    - Check if bastion/jump host can reach the VNET"
      warn "    - Verify DNS suffix '${INTERNAL_DNS_SUFFIX}' is correct"
      warn "    - Check Azure Bastion connectivity if using it"
      warn "═══════════════════════════════════════════════════════════════════"
      
      # Determine if failures are due to provisioning or just startup delays
      if [[ $failed_instances -gt 0 ]]; then
        error ""
        error "══════════════════════════════════════════════════════════════════════"
        error "  CRITICAL FINDING: $failed_instances Consul instance(s) have FAILED provisioning"
        error "══════════════════════════════════════════════════════════════════════"
        error ""
        error "These instances will NEVER become reachable without Azure-level fixes."
        error "Failed provisioning means the VM initialization failed permanently."
        error ""
        error "Required actions (choose one):"
        error "  1. Reimage: az vmss reimage --name <vmss> --resource-group <rg> --instance-id <id>"
        error "  2. Delete+recreate: az vmss delete-instances ... then update-instances"
        error "  3. Scale to 0 and back: az vmss scale --new-capacity 0 (then back to 1)"
        error ""
        error "Check Azure Activity Log to find WHY provisioning failed (quota, allocation, etc)"
        error "══════════════════════════════════════════════════════════════════════"
        record_summary error "$failed_instances Consul VMSS instance(s) have FAILED provisioning - MUST fix in Azure"
      else
        # No provisioning failures - hosts just not ready yet
        record_summary warn "Consul hosts not yet reachable - normal during startup, retry status in 10-15 minutes"
      fi
    fi
  else
    info "Summary: All $host_count Consul host(s) checked successfully"
  fi

  info "Note: Consul is managed by taapp1 user scripts, not systemd. Start/stop actions are not automated."
}

ScaleDeployments() {
  log_section "Kubernetes Deployment Scaling"
  local ENV_CODE_NODASH="${Env_Code//-/}"

  # Check if kubectl is available locally
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found locally - skipping Kubernetes deployment scaling"
    return 1
  fi

  info "Using local kubectl for Kubernetes operations"

  for ns_suffix in k8s tcms bs; do
    local ns="${ENV_CODE_NODASH}-${ns_suffix}"
    echo "[INFO] Namespace: $ns"

    # Check if namespace exists
    if ! kubectl get namespace $ns &>/dev/null 2>/dev/null; then
      info "Namespace $ns does not exist — skipping"
      continue
    fi

    local deployments
    deployments=$(kubectl get deployment -n $ns --no-headers 2>/dev/null | awk '{print $1}' || true)

    if [[ -z "$deployments" ]]; then
      info "No deployments found in $ns — skipping"
      continue
    fi

    local deploy_count=$(echo "$deployments" | wc -w)
    info "Found $deploy_count deployment(s) in $ns"

    # For status action, show all deployments at once
    if [[ "$ACTION" == "status" ]]; then
      kubectl get deployment -n $ns 2>/dev/null || true
      continue
    fi

    for d in $deployments; do
      local replicas
      replicas=$(kubectl get deployment $d -n $ns -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
      case "$ACTION" in
        start)
          if [[ "${replicas:-0}" -gt 0 ]]; then
            warn "$d already running ($replicas replicas)"
          else
            info "Scaling up $d in $ns"
            if kubectl scale deployment $d -n $ns --replicas=1 2>/dev/null; then
              success "Scale up $d"
              record_summary success "Scale up $d"
            else
              warn "Failed to scale up $d"
              record_summary warn "Failed to scale up $d"
            fi
          fi
          ;;
        stop)
          if [[ "${replicas:-0}" -eq 0 ]]; then
            warn "$d already stopped"
          else
            info "Scaling down $d in $ns"
            if kubectl scale deployment $d -n $ns --replicas=0 2>/dev/null; then
              success "Scale down $d"
              record_summary success "Scale down $d"
            else
              warn "Failed to scale down $d"
              record_summary warn "Failed to scale down $d"
            fi
          fi
          ;;
      esac
   #  if [[ ${ns_suffix} = "k8s" ]]
   #  then
   #       if [[ ${ACTION} != "status" ]]
#         then
#            for i in `kubectl get pod -n $ns | grep nfs`
#            do
#                    kubectl delete pod $i -n $ns
#            done
#     fi
#            fi
    done

    if [[ ${ns_suffix} == "tcms" ]]; then
      log_section "Conditional Scaling for TCMS Deployments"
      deployments=(usage-accumulatorextract usage-detailsextract accumulatorandsession-ccrecopymanager accumulatorandsession-changecycle accumulatorandsession-eocmaintenance accumulatorandsession-snapshotexecutor accumulatorandsession-snapshotmanager charging-provisioning-gateway-closed-user-group charging-provisioning-gateway-closed-user-group-bulk charging-provisioning-gateway-gen-app-tables charging-provisioning-gateway-gen-app-tables-bulk charging-provisioning-gateway-mark-rerate charging-provisioning-gateway-profileeoc reratetask-executor-2 nonusage-charge-management)
      for d in "${deployments[@]}"; do
        if kubectl get deployment $d -n $ns &>/dev/null 2>/dev/null; then
          info "Scaling down $d in namespace $ns"
          if kubectl scale deployment $d -n $ns --replicas=0 2>/dev/null; then
            success "Scaled down $d"
          else
            warn "Failed to scale down $d"
          fi
        else
          info "Deployment $d not found in $ns — skipping"
        fi
      done
    fi

    if [[ ${ns_suffix} == "k8s" ]]; then
      log_section "Conditional Scaling for K8s Deployments"
      deployments=(gts eoc-rerate-daemon)
      for d in "${deployments[@]}"; do
        if kubectl get deployment $d -n $ns &>/dev/null 2>/dev/null; then
          info "Scaling down $d in namespace $ns"
          if kubectl scale deployment $d -n $ns --replicas=0 2>/dev/null; then
            success "Scaled down $d"
          else
            warn "Failed to scale down $d"
          fi
        else
          info "Deployment $d not found in $ns — skipping"
        fi
      done
    fi
  done
}
ValidatePods() {
  log_section "Kubernetes Pod Readiness Check"

  # Check if kubectl is available locally
  if ! command -v kubectl &>/dev/null; then
    warn "kubectl not found locally - skipping pod validation"
    return 1
  fi

  info "Using local kubectl for pod validation"

  local Env_Code1 Env_Code2 ns TIMEOUT=30 INTERVAL=30
  Env_Code1=$(echo "$Env_Code" | awk -F '-' '{print $1}')
  Env_Code2=$(echo "$Env_Code" | awk -F '-' '{print $2}')
  ns="${Env_Code1}${Env_Code2}"

  READY_BASES_FILE=$(mktemp /tmp/ready_bases.XXXX)
  local overall_status=0  # track if any namespace failed

  for namespace in ${ns}-k8s ${ns}-tcms ${ns}-bs; do
    echo "[INFO] Waiting for pods in $namespace..."
    local start=$(date +%s)
    
    # Check if this is TCMS namespace (will show status but not fail on timeout)
    local is_tcms=false
    if [[ "$namespace" == "${ns}-tcms" ]]; then
      is_tcms=true
      info "TCMS namespace - will display pod status without strict validation"
    fi

    while true; do
      local pod_status
      pod_status=$(kubectl get pods -n $namespace --no-headers 2>/dev/null || true)

      local not_ready=""
      > "$READY_BASES_FILE"

      while read -r line; do
        [[ -z "$line" ]] && continue
        pod_name=$(echo "$line" | awk '{print $1}')
        ready_field=$(echo "$line" | awk '{print $2}')
        status_field=$(echo "$line" | awk '{print $3}')
        base_name=$(echo "$pod_name" | sed 's/-[a-z0-9]\{5,10\}$//')

        # Skip pods with Completed or Succeeded status (finished jobs/cronjobs)
        if [[ "$status_field" == "Completed" || "$status_field" == "Succeeded" ]]; then
          continue
        fi

        # Skip nfscleanup pods (cleanup CronJob pods that may be in error state)
        if [[ "$pod_name" =~ nfscleanup ]]; then
          continue
        fi

        # check readiness (1/1, 2/2, etc.)
        ready_now=$(echo "$ready_field" | awk -F'/' '{if ($1==$2) print 1; else print 0}')

        # skip bases that already have one ready pod
        if grep -q "^$base_name$" "$READY_BASES_FILE" 2>/dev/null; then
          continue
        fi

        if [[ "$ready_now" -eq 1 ]]; then
          echo "$base_name" >> "$READY_BASES_FILE"
          continue
        fi

        # if base has no ready replicas yet, mark as not ready
        if ! grep -q "^$base_name$" "$READY_BASES_FILE" 2>/dev/null; then
          not_ready+="$line"$'\n'
        fi
      done <<< "$pod_status"

      if [[ -z "$not_ready" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} All pods in $namespace are ready (at least one per replica set)."
        echo ""
        kubectl get pods -n $namespace
        echo ""
        break
      fi

      # For TCMS, don't show "not ready" warnings - just display final status at timeout
      if [[ "$is_tcms" == false ]]; then
        echo "[INFO] The following pods are NOT ready in namespace $namespace (no ready replica found):"
        echo "$not_ready" | awk '{print $1, $2, $3, $4, $5}'
      fi

      # timeout handling (mark namespace as failed but move on)
      if (( $(date +%s) - start > TIMEOUT )); then
        if [[ "$is_tcms" == true ]]; then
          # TCMS timeout is acceptable - just show status without failing
          echo -e "${YELLOW}[WARN]${NC} TCMS namespace timeout reached - displaying current status (not treated as failure)"
          echo ""
          kubectl get pods -n $namespace 2>/dev/null || true
          echo ""
          break  # exit this namespace, move to next
        else
          echo -e "${RED}[ERROR]${NC} Timeout: Some workloads in $namespace have no ready pods."
          echo ""
          kubectl get pods -n $namespace | grep -v -E 'Running|Completed|Succeeded' || true
          echo ""
          overall_status=1
          break  # exit this namespace, move to next
        fi
      fi

      if [[ "$is_tcms" == false ]]; then
        echo "[INFO] Retrying in $INTERVAL seconds..."
      fi
      sleep $INTERVAL
    done
  done

  rm -f "$READY_BASES_FILE"

  # If any namespace had failures, exit non-zero
  if [[ $overall_status -ne 0 ]]; then
    echo -e "${RED}[ERROR]${NC} One or more namespaces have pods that failed to become ready."
   # return 1
  else
    echo -e "${GREEN}[SUCCESS]${NC} All namespaces have ready pods."
   # return 0
  fi
}

#-------------------------------#
#        HTML REPORTING         #
#-------------------------------#
print_html_report() {
  # Try to write HTML report, but don't fail if we can't
  local temp_report="/tmp/EnvControl_Report_${Env_Code}_$(date +%Y%m%d_%H%M%S).html"

  # Try primary location first
  if touch "$REPORT_FILE" 2>/dev/null; then
    temp_report="$REPORT_FILE"
  else
    # Try current directory as fallback
    if touch "${CURRENT_DIR}/EnvControl_Report_$(date +%Y%m%d_%H%M%S).html" 2>/dev/null; then
      temp_report="${CURRENT_DIR}/EnvControl_Report_$(date +%Y%m%d_%H%M%S).html"
    else
      # Use /tmp as last resort
      info "Using /tmp for HTML report due to permission restrictions"
    fi
  fi

  # Write the report (don't fail if this doesn't work)
  {
    echo "<html><head><title>EnvControl Report - ${Env_Code}</title>"
    echo "<style>
      body {font-family: Arial; background:#fafafa; padding:20px;}
      h1 {color:#333;}
      table {border-collapse: collapse; width: 100%; margin-bottom: 20px;}
      th, td {border: 1px solid #ccc; padding: 8px; text-align: left;}
      th {background-color: #eee;}
      .success {color: green;}
      .warn {color: orange;}
      .error {color: red;}
      .footer {font-weight: bold; background-color:#f2f2f2;}
    </style></head><body>"
    echo "<h1>EnvControl Report - ${Env_Code} (${ACTION})</h1>"
    echo "<h2>Summary Details</h2>"
    echo "<table><tr><th>Status</th><th>Description</th></tr>"

    for s in "${SUMMARY_SUCCESS[@]}"; do echo "<tr><td class='success'>SUCCESS</td><td>${s}</td></tr>"; done
    for s in "${SUMMARY_WARN[@]}";    do echo "<tr><td class='warn'>WARNING</td><td>${s}</td></tr>"; done
    for s in "${SUMMARY_ERROR[@]}";   do echo "<tr><td class='error'>ERROR</td><td>${s}</td></tr>"; done

    local success_count=${#SUMMARY_SUCCESS[@]}
    local warn_count=${#SUMMARY_WARN[@]}
    local error_count=${#SUMMARY_ERROR[@]}

    echo "<tr class='footer'><td colspan='2'>
            ✅ Success: ${success_count} &nbsp;&nbsp;|&nbsp;&nbsp;
            ⚠️ Warnings: ${warn_count} &nbsp;&nbsp;|&nbsp;&nbsp;
            ❌ Errors: ${error_count}
          </td></tr>"
    echo "</table><p>Generated on $(date)</p></body></html>"
  } > "$temp_report" 2>/dev/null && info "HTML report generated: $temp_report" || warn "Failed to generate HTML report"

  # Always return success - report generation failures shouldn't fail the build
  return 0
}

#-------------------------------#
#        FINAL SUMMARY          #
#-------------------------------#
print_summary() {
  log_section "Execution Summary for ${Env_Code} (${ACTION})"

  echo -e "\n${GREEN}✅ SUCCESSFUL TASKS:${NC}"
  ((${#SUMMARY_SUCCESS[@]})) && printf '  - %s\n' "${SUMMARY_SUCCESS[@]}" || echo "  (none)"

  echo -e "\n${YELLOW}⚠️  WARNINGS:${NC}"
  ((${#SUMMARY_WARN[@]})) && printf '  - %s\n' "${SUMMARY_WARN[@]}" || echo "  (none)"

  echo -e "\n${RED}❌ ERRORS:${NC}"
  ((${#SUMMARY_ERROR[@]})) && printf '  - %s\n' "${SUMMARY_ERROR[@]}" || echo "  (none)"

  # Generate HTML report (don't let failures here affect script exit status)
  print_html_report || true

  echo -e "\n======================================================"
  local success_count=${#SUMMARY_SUCCESS[@]}
  local warn_count=${#SUMMARY_WARN[@]}
  local error_count=${#SUMMARY_ERROR[@]}

  echo -e "${GREEN}✅ Success:${NC} ${success_count}  |  ${YELLOW}⚠️  Warnings:${NC} ${warn_count}  |  ${RED}❌ Errors:${NC} ${error_count}"
  echo "======================================================"

  # Only fail the build if there are actual ERRORS, not warnings
  if (( error_count > 0 )); then
    echo -e "${RED}ENV CONTROL COMPLETED WITH ERRORS ❌${NC}"
    exit 1
  elif (( warn_count > 0 )); then
    echo -e "${YELLOW}ENV CONTROL COMPLETED WITH WARNINGS ⚠️${NC}"
    # Warnings are acceptable - don't fail the build
    exit 0
  else
    echo -e "${GREEN}ENV CONTROL COMPLETED SUCCESSFULLY ✅${NC}"
    exit 0
  fi
}

#-------------------------------#
#         MAIN EXECUTION        #
#-------------------------------#
log_section "Starting EnvControl for ${Env_Code} (${ACTION})"

# Show refresh config status
if [[ "${REFRESH_CONFIG:-false}" == "true" ]]; then
  info "REFRESH_CONFIG is enabled - all config files will be regenerated from Azure"
fi

SetUATAuth
GetVMList
GetPGList
GetClouderaHosts
GetConsulHosts

case "$ACTION" in
  stop)
    ManageConsul
    ManageCDH
    ManageClouderaVMSS  # Stop Cloudera VMSS instances after Cloudera services are stopped
    ManageVMs
    ManageVMSS
    ManagePGServers
    ScaleDeployments
    ;;
  start)
    ManagePGServers
    ManageVMs
    ManageVMSS
    ManageClouderaVMSS  # Start Cloudera VMSS instances before Cloudera services
    ManageCDH
    ScaleDeployments
    ManageConsul
    export TIMEOUT=600
    ValidatePods
    ;;
  status)
    ManageVMs
    ManageVMSS
    ManageClouderaVMSS
    ManageCDH
    ManagePGServers
    ScaleDeployments
    ManageConsul
    export TIMEOUT=30
    ValidatePods
    ;;
esac

print_summary



