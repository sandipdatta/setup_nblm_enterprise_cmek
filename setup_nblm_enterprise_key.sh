#!/bin/bash

# Script to enable APIs, create KMS resources, set IAM, and configure CMEK
# for NotebookLM Enterprise.
# It interactively prompts for project ID, key ring name, key name, and protection level.

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
# These locations can be modified if needed.
KMS_LOCATION="europe"
DATA_STORE_LOCATION="eu" # 'us' or 'eu'

# --- Logging Functions ---
# Usage: log "Your log message here"
log() {
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$timestamp] [INFO] $1"
}

# Usage: error_log "Your error message here"
error_log() {
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$timestamp] [ERROR] $1" >&2
}

# --- Script Usage ---
usage() {
    echo "Usage: $0"
    echo "This script is fully interactive. It will prompt you for all required information,"
    echo "including the Google Cloud Project ID, KMS Key Ring name, Key name,"
    echo "and whether to use HSM or Software protection."
    echo ""
    echo "NOTE: This script uses 'jq' for JSON parsing. Please ensure it is installed."
    exit 1
}

# --- Prerequisite Check ---
# Check if jq is installed, as it was required by the original verification logic.
if ! command -v jq &> /dev/null; then
    error_log "'jq' is not installed, but it is a potential dependency."
    error_log "Please install jq to prevent future issues. Example: sudo apt-get install jq OR brew install jq"
fi

# --- Interactive User Input ---
log "Gathering configuration details..."

# Prompt for Google Cloud Project ID
read -p "Enter your Google Cloud Project ID: " GCLOUD_PROJECT_ID
if [ -z "$GCLOUD_PROJECT_ID" ]; then
    error_log "Google Cloud Project ID cannot be empty."
    exit 1
fi

# Prompt for Key Ring Name with a default value
read -p "Enter the Key Ring Name [default: notebooklm_keyring]: " KEYRING_NAME
KEYRING_NAME=${KEYRING_NAME:-notebooklm_keyring} # Assign default if input is empty

# Prompt for Key Name with a default value
read -p "Enter the Key Name [default: notebooklm_cmek_key]: " KEY_NAME
KEY_NAME=${KEY_NAME:-notebooklm_cmek_key} # Assign default if input is empty

# Prompt for HSM or Software protection level
protection_level=""
while [[ "$protection_level" != "hsm" && "$protection_level" != "software" ]]; do
    read -p "Enter the protection level ('hsm' or 'software') [default: software]: " protection_level
    protection_level=${protection_level:-software} # Assign default if input is empty
    if [[ "$protection_level" != "hsm" && "$protection_level" != "software" ]]; then
        error_log "Invalid input. Please enter 'hsm' or 'software'."
    fi
done

# Set arguments and description based on user's choice
protection_level_arg="--protection-level $protection_level"
if [[ "$protection_level" == "hsm" ]]; then
    protection_level_desc="HSM (Hardware Security Module)"
else
    protection_level_desc="Software"
fi
log "Protection level has been set to '$protection_level'."


# --- Main Script ---
log "Starting setup process for project: $GCLOUD_PROJECT_ID"
log "Using Key Ring: '$KEYRING_NAME', Key: '$KEY_NAME', Protection: $protection_level_desc"
log "KMS Location: $KMS_LOCATION, Data Store Location: $DATA_STORE_LOCATION"

# == 1. Enable APIs ==
log "Enabling Cloud Key Management Service (KMS) API (cloudkms.googleapis.com)..."
if gcloud services enable cloudkms.googleapis.com --project="$GCLOUD_PROJECT_ID"; then
    log "Successfully enabled Cloud Key Management Service (KMS) API."
else
    error_log "Failed to enable Cloud Key Management Service (KMS) API."
    exit 1
fi

log "Enabling Discovery Engine API (discoveryengine.googleapis.com)..."
if gcloud services enable discoveryengine.googleapis.com --project="$GCLOUD_PROJECT_ID"; then
    log "Successfully enabled Discovery Engine API."
else
    error_log "Failed to enable Discovery Engine API."
    exit 1
fi

# == 2. Ensure Service Agents Exist ==
log "Ensuring Discovery Engine service agent exists..."
# This command creates the service identity if it doesn't exist.
if gcloud beta services identity create --service=discoveryengine.googleapis.com --project="$GCLOUD_PROJECT_ID" &>/dev/null; then
    log "Successfully ensured Discovery Engine service agent is provisioned."
else
    log "Attempted to ensure Discovery Engine service agent. If it already existed, this is fine."
fi

log "Ensuring Cloud Storage service agent exists..."
# This command ensures the GCS service account is provisioned for the project.
if gcloud storage service-agent --project="$GCLOUD_PROJECT_ID" > /dev/null; then
    log "Successfully ensured Cloud Storage service agent is provisioned."
else
    error_log "Failed to ensure Cloud Storage service agent."
fi

# == 3. Fetch Project Number ==
log "Fetching project number for $GCLOUD_PROJECT_ID..."
PROJECT_NUMBER=$(gcloud projects describe "$GCLOUD_PROJECT_ID" --format="value(projectNumber)")
if [ -z "$PROJECT_NUMBER" ]; then
    error_log "Failed to fetch project number for project $GCLOUD_PROJECT_ID."
    exit 1
fi
log "Successfully fetched project number: $PROJECT_NUMBER."

# Construct the service account names using the fetched project number
DISCOVERY_ENGINE_SA="service-$PROJECT_NUMBER@gcp-sa-discoveryengine.iam.gserviceaccount.com"
STORAGE_SA="service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com"
KMS_CRYPTO_ROLE="roles/cloudkms.cryptoKeyEncrypterDecrypter"

log "Target Discovery Engine Service Agent for IAM: $DISCOVERY_ENGINE_SA"
log "Target Cloud Storage Service Agent for IAM: $STORAGE_SA"

# == 4. Create KMS Key Ring ==
log "Creating KMS Key Ring '$KEYRING_NAME' in location '$KMS_LOCATION'..."
# The '|| true' allows the script to continue if the keyring already exists.
# Error output is redirected to /dev/null to avoid cluttering the log if it exists.
gcloud kms keyrings create "$KEYRING_NAME" \
    --location "$KMS_LOCATION" \
    --project "$GCLOUD_PROJECT_ID" 2>/dev/null || true

# Verify that the key ring now exists before proceeding.
if gcloud kms keyrings describe "$KEYRING_NAME" --location "$KMS_LOCATION" --project "$GCLOUD_PROJECT_ID" &>/dev/null; then
    log "KMS Key Ring '$KEYRING_NAME' exists in location '$KMS_LOCATION'. Proceeding."
else
    error_log "Failed to create or find KMS Key Ring '$KEYRING_NAME'."
    exit 1
fi


# == 5. Create KMS Key (Symmetric, with user-defined protection) ==
log "Creating KMS Key '$KEY_NAME' in Key Ring '$KEYRING_NAME' with $protection_level_desc protection..."

# The $protection_level_arg variable will explicitly be "--protection-level software" or "--protection-level hsm".
if gcloud kms keys create "$KEY_NAME" \
    --keyring "$KEYRING_NAME" \
    --location "$KMS_LOCATION" \
    --purpose "encryption" \
    $protection_level_arg \
    --project "$GCLOUD_PROJECT_ID"; then
    log "Successfully created KMS Key with $protection_level_desc protection."
else
    # If key creation fails, check if it's because the key already exists.
    if gcloud kms keys describe "$KEY_NAME" --keyring "$KEYRING_NAME" --location "$KMS_LOCATION" --project "$GCLOUD_PROJECT_ID" &>/dev/null; then
        log "KMS Key '$KEY_NAME' already exists in Key Ring '$KEYRING_NAME'. Proceeding."
    else
        error_log "Failed to create KMS Key '$KEY_NAME'."
        exit 1
    fi
fi

# == 6. Grant IAM Permissions on the Key ==
log "Granting IAM role '$KMS_CRYPTO_ROLE' to Discovery Engine SA ($DISCOVERY_ENGINE_SA) on key '$KEY_NAME'..."
if gcloud kms keys add-iam-policy-binding "$KEY_NAME" \
    --keyring "$KEYRING_NAME" \
    --location "$KMS_LOCATION" \
    --member "serviceAccount:$DISCOVERY_ENGINE_SA" \
    --role "$KMS_CRYPTO_ROLE" \
    --project "$GCLOUD_PROJECT_ID" \
    --condition=None --quiet; then
    log "Successfully granted or verified '$KMS_CRYPTO_ROLE' to Discovery Engine SA."
else
    error_log "Failed to grant '$KMS_CRYPTO_ROLE' to Discovery Engine SA ($DISCOVERY_ENGINE_SA)."
fi

log "Granting IAM role '$KMS_CRYPTO_ROLE' to Cloud Storage SA ($STORAGE_SA) on key '$KEY_NAME'..."
if gcloud kms keys add-iam-policy-binding "$KEY_NAME" \
    --keyring "$KEYRING_NAME" \
    --location "$KMS_LOCATION" \
    --member "serviceAccount:$STORAGE_SA" \
    --role "$KMS_CRYPTO_ROLE" \
    --project "$GCLOUD_PROJECT_ID" \
    --condition=None --quiet; then
    log "Successfully granted or verified '$KMS_CRYPTO_ROLE' to Cloud Storage SA."
else
    error_log "Failed to grant '$KMS_CRYPTO_ROLE' to Cloud Storage SA ($STORAGE_SA)."
fi

log "--- SETUP COMPLETE ---"
log "Key Ring: $KEYRING_NAME, Key: $KEY_NAME, KMS Location: $KMS_LOCATION."
log "Data Store Location: $DATA_STORE_LOCATION."
log "The KMS key has been created and configured with the necessary IAM permissions for NotebookLM Enterprise in $DATA_STORE_LOCATION for project $GCLOUD_PROJECT_ID."

