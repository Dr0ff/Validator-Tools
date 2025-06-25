#!/bin/bash

# auto_vote.sh
# run with --debug flag to get verbose mode. Example: bash auto_vote.sh --debug

# --- Telegram Notification Configuration ---
# Set to true to enable Telegram notifications, false to disable.
ENABLE_TELEGRAM_NOTIFICATIONS=true # <<< SET to true to enable
# Your Telegram Bot Token (get from @BotFather)
TELEGRAM_BOT_TOKEN="ВАШ_БОТ_ТОКЕН" # <<< REQUIRED if ENABLE_TELEGRAM_NOTIFICATIONS is true
# Your Telegram Chat ID (can be user ID or group/channel ID like -123456789)
TELEGRAM_CHAT_ID="ВАШ_CHAT_ID"     # <<< REQUIRED if ENABLE_TELEGRAM_NOTIFICATIONS is true
USER_TO_PING=""

# --- Configuration for Your Network ---

NETWORK_NAME="NOLUS"

# Name of the CLI binary for the chain (e.g., 'sommelier', 'junod', 'nolusd', etc.)
CLI_NAME="nolusd" # <<< VERIFY this is the correct command for your node

# --- Node Configuration ---
# Set to true to use your synchronized local node (omits --node flag, CLI will use its default)
# Set to false to use the NODE_URL.

USE_LOCAL_NODE=true # <<< CHOOSE true OR false
# URL for the remote RPC node (only used if USE_LOCAL_NODE is false)
# For Nolus, this should be an RPC endpoint, NOT a REST endpoint.
# Example for Nolus RPC: "https://rpc.nolus.io:443" or "tcp://rpc.nolus.io:26657"
# If USE_LOCAL_NODE is true, this value is ignored.

NODE_URL="https://rpc-node-url:port" # <<< SET THIS IF USING A REMOTE NODE and USE_LOCAL_NODE is false

# --- Chain & Voter Configuration ---
CHAIN_ID="pirin-1"             # <<< VERIFY! Actual Chain ID for network
VOTERWALLET="votewallet"       # Your key name or nolus1... address
FEES="5000unls"                # <<< VERIFY! Example fees in Nolus' native token (e.g., unls)

# --- Script Behavior Configuration ---
# Limit for querying active proposals
ACTIVE_PROPOSALS_QUERY_LIMIT=10 # You can increase this if you expect more active proposals simultaneously
# If voting_end_time is within this many seconds, consider it "last day" for voting
VOTE_WINDOW_SECONDS=$((60 * 60 * 4)) # 4 hours before end of voting (as requested)

GAS="auto"
GAS_ADJUSTMENT="1.4"

# State file (stores only voted proposals)
CURRENT_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
STATE_FILE="${CURRENT_SCRIPT_DIR}/${CLI_NAME}_vote_state.json"

# --- DEBUGGING CONTROL ---
DEBUG_MODE=false
if [[ "$1" == "--debug" ]]; then
    DEBUG_MODE=true
    echo "DEBUG: Debug mode is ON."
fi

# Function to print debug messages
debug_echo() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "DEBUG: $1"
    fi
}

# --- Telegram Notification Function ---
send_telegram_message() {
    local message="$1"

    if [ "$ENABLE_TELEGRAM_NOTIFICATIONS" = false ]; then
        debug_echo "INFO: Telegram notifications are disabled in configuration. Skipping."
        return 0 # Выходим без ошибки, так как это ожидаемое поведение
    fi

    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        debug_echo "WARN: Telegram BOT_TOKEN or CHAT_ID is not set in configuration despite notifications being enabled. Skipping Telegram notification."
        return 1
    fi

    local URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    curl -s -X POST "${URL}" \
         -H "Content-Type: application/json" \
         -d "{
             \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
             \"text\": \"${message}\",
             \"parse_mode\": \"Markdown\"
         }" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        debug_echo "Telegram message sent successfully."
    else
        debug_echo "ERROR: Failed to send Telegram message."
        # Опционально: можно добавить здесь логирование конкретной ошибки curl
        # (но это может быть громоздко)
    fi
}
# --- End of Telegram Notification Function ---


# --- Determine Node Command Flag (using array for robustness) ---
NODE_COMMAND_PART_ARRAY=() # Will be empty for local node, or --node <URL> for remote

if [ "$USE_LOCAL_NODE" = true ]; then
    echo "INFO: Script configured to use LOCAL node (via CLI default settings, usually tcp://localhost:26657)."
else
    if [ -z "$NODE_URL" ] || [[ "$NODE_URL" == "https://rpc-node-url:port" ]]; then
        echo "ERROR: USE_LOCAL_NODE is false, but NODE_URL is not set or is still the placeholder. Please configure it."
        exit 1
    fi
    # Validate NODE_URL for RPC connections (must start with tcp:// or contain : for port)
    if [[ ! "$NODE_URL" =~ ^tcp:// ]] && [[ ! "$NODE_URL" =~ :[0-9]+$ ]]; then
        echo "ERROR: NODE_URL '$NODE_URL' does not appear to be a valid RPC endpoint format (e.g., tcp://host:port or host:port)."
        exit 1
    fi
    NODE_COMMAND_PART_ARRAY=("--node" "$NODE_URL")
    echo "INFO: Script configured to use REMOTE node: $NODE_URL"
fi

# --- Helper Functions ---
iso_to_epoch() {
    # GNU date specific. May need adjustment on macOS or other systems.
    date -u -d "$1" +%s 2>/dev/null
}
current_epoch() {
    date -u +%s
}

# --- Main Logic ---
echo "INFO: ${CLI_NAME} Simplified Voting Script started at $(date -u -R)"
echo "INFO: Voter Address/Key: $VOTERWALLET"
echo "INFO: Chain ID: $CHAIN_ID"

# --- Load Previously Voted Proposals from State File ---
proposals_voted_on_json="{}" # Default to empty JSON object string
if [[ -f "$STATE_FILE" ]]; then
    echo "INFO: Reading state from '$STATE_FILE'..."
    if jq -e '.proposals_voted_on | type == "object"' "$STATE_FILE" > /dev/null 2>&1; then
        proposals_voted_on_json=$(jq -c '.proposals_voted_on' "$STATE_FILE")
    else
        echo "WARN: 'proposals_voted_on' not found or not an object in state file. Defaulting to {}."
    fi
    debug_echo "Loaded voted proposals (condensed): $proposals_voted_on_json"
else
    echo "INFO: '$STATE_FILE' not found. Initializing with empty voted list."
fi

# --- Fetch Active Proposals ---
echo "INFO: Fetching up to $ACTIVE_PROPOSALS_QUERY_LIMIT most recent active proposals..."

# Base command arguments, always the same for queries
PROPOSAL_QUERY_BASE_ARGS=(
    "$CLI_NAME" "q" "gov" "proposals"
    "${NODE_COMMAND_PART_ARRAY[@]}" # Expands to --node URL or nothing
    "--chain-id" "$CHAIN_ID"
    "--output" "json"
)

# Arguments for modern Cosmos SDK flags (v0.47+ usually)
QUERY_FLAGS_MODERN_ARGS=(
    "--reverse"
    "--limit" "$ACTIVE_PROPOSALS_QUERY_LIMIT"
    "--status" "voting_period"
)

# Arguments for older/nolusd-specific flags
# IMPORTANT: Values like '10' and 'voting-period' are NOT quoted in the array definition
# because nolusd complained about literal quotes being passed in previous debug outputs.
QUERY_FLAGS_OLD_ARGS=(
    "--page-reverse"
    "--page-limit" "$ACTIVE_PROPOSALS_QUERY_LIMIT" # Keeping value quoted here. Array handling might pass it correctly.
    "--proposal-status" "voting-period"             # Keeping value quoted here. Array handling might pass it correctly.
)

# Attempt with modern flags
debug_echo "Attempting query with modern flags: ${PROPOSAL_QUERY_BASE_ARGS[@]} ${QUERY_FLAGS_MODERN_ARGS[@]}"
cli_output=$("${PROPOSAL_QUERY_BASE_ARGS[@]}" "${QUERY_FLAGS_MODERN_ARGS[@]}" 2>&1)
cli_status=$?

# Check for "unknown flag" error to determine which set of flags to use
if [[ "$cli_output" == *"Error: unknown flag"* ]]; then
    echo "WARN: Detected unknown flag error with modern query flags. Retrying with older flags."
    debug_echo "Attempting query with old flags: ${PROPOSAL_QUERY_BASE_ARGS[@]} ${QUERY_FLAGS_OLD_ARGS[@]}"
    cli_output=$("${PROPOSAL_QUERY_BASE_ARGS[@]}" "${QUERY_FLAGS_OLD_ARGS[@]}" 2>&1)
    cli_status=$?
fi

debug_echo "CLI Command Exit Status: $cli_status"
debug_echo "Raw CLI Output (first 500 chars): ${cli_output:0:500}..."
debug_echo "End of Raw CLI Output."

if [[ $cli_status -ne 0 ]]; then
    echo "ERROR: CLI command failed with status $cli_status. Full output for debugging:"
    echo "$cli_output"
    echo "Exiting due to CLI command failure."
    exit 1
fi

# Attempt to parse proposals from the raw CLI output
# This part handles both v1 and v1beta1 (id vs proposal_id) and should be robust
active_proposal_ids_json=$(echo "$cli_output" | jq -c '[.proposals[].proposal_id // .proposals[].id | select(. != null)]' 2>/dev/null)
jq_status=$?

debug_echo "JQ parsing status: $jq_status"
debug_echo "JQ Output for active_proposal_ids_json: '$active_proposal_ids_json'"

if [[ $jq_status -ne 0 || -z "$active_proposal_ids_json" || "$active_proposal_ids_json" == "[]" || "$active_proposal_ids_json" == "null" ]]; then
    echo "INFO: No active proposals found, or parsing failed. No proposals to process."
    debug_echo "Reason: JQ status ($jq_status), empty output ($active_proposal_ids_json)."
    active_proposal_ids=()
else
    mapfile -t active_proposal_ids < <(echo "$active_proposal_ids_json" | jq -r '.[]')
fi

echo "INFO: Found ${#active_proposal_ids[@]} active proposal(s) directly from query."
echo "------------------------------------------------------"

if [[ ${#active_proposal_ids[@]} -eq 0 ]]; then
    echo "INFO: No active proposals found to process."
else
    NOW_EPOCH=$(current_epoch)
    for proposal_id in "${active_proposal_ids[@]}"; do
        echo ""
        echo "Processing Active Proposal ID: $proposal_id"

        if echo "$proposals_voted_on_json" | jq -e ".\"$proposal_id\"" > /dev/null; then
            echo "INFO: Already voted on proposal $proposal_id based on state file. Skipping."
            continue
        fi

        # Fetch full proposal details to get voting_end_time (using arrays)
        debug_echo "Fetching full details for proposal $proposal_id..."
        PROPOSAL_DETAILS_ARGS=(
            "$CLI_NAME" "q" "gov" "proposal" "$proposal_id"
            "${NODE_COMMAND_PART_ARRAY[@]}"
            "--chain-id" "$CHAIN_ID"
            "--output" "json"
        )
        debug_echo "Proposal details command: ${PROPOSAL_DETAILS_ARGS[@]}"
        proposal_data=$("${PROPOSAL_DETAILS_ARGS[@]}" 2>&1)
        proposal_data_status=$?

        debug_echo "Proposal details CLI Exit Status: $proposal_data_status"
        debug_echo "Raw proposal data (first 500 chars): ${proposal_data:0:500}..."

        if [[ $proposal_data_status -ne 0 || -z "$proposal_data" ]]; then
            echo "ERROR: Failed to fetch details for proposal $proposal_id. Skipping."
            debug_echo "Full error output for proposal details: $proposal_data"
            continue
        fi

        # IMPORTANT: Verify JQ path for .voting_end_time for Nolus (v1 vs v1beta1)
        voting_end_time_iso=$(echo "$proposal_data" | jq -r '.voting_end_time // .proposal.voting_end_time // ""')
        debug_echo "Parsed voting_end_time_iso: '$voting_end_time_iso'"
        VOTING_END_EPOCH=$(iso_to_epoch "$voting_end_time_iso")

        if [[ -z "$VOTING_END_EPOCH" || "$VOTING_END_EPOCH" -eq 0 ]]; then
            echo "ERROR: Could not parse voting_end_time for $proposal_id ('$voting_end_time_iso'). Skipping."
            continue
        fi

        time_remaining_seconds=$((VOTING_END_EPOCH - NOW_EPOCH))
        time_remaining_hours=$(awk "BEGIN {printf \"%.2f\", $time_remaining_seconds / 3600}")
        echo "Voting End Time: $voting_end_time_iso | Time Remaining: $time_remaining_hours hours"

        if [[ $time_remaining_seconds -le $VOTE_WINDOW_SECONDS && $time_remaining_seconds -gt 0 ]]; then
            echo "INFO: Proposal $proposal_id is within the voting window. Fetching tally..."

            # Fetch tally details (using arrays)
            debug_echo "Fetching tally for proposal $proposal_id..."
            TALLY_ARGS=(
                "$CLI_NAME" "q" "gov" "tally" "$proposal_id"
                "${NODE_COMMAND_PART_ARRAY[@]}"
                "--chain-id" "$CHAIN_ID"
                "--output" "json"
            )
            debug_echo "Tally command: ${TALLY_ARGS[@]}"
            tally_data=$("${TALLY_ARGS[@]}" 2>&1)
            tally_status=$?

            debug_echo "Tally CLI Exit Status: $tally_status"
            debug_echo "Raw tally data (first 500 chars): ${tally_data:0:500}..."

            if [[ $tally_status -ne 0 || -z "$tally_data" ]]; then
                echo "ERROR: Failed to fetch tally for $proposal_id. Skipping."
                debug_echo "Full error output for tally: $tally_data"
                continue
            fi

            # IMPORTANT: VERIFY THESE JQ PATHS with actual 'YOUR_DAEMON q gov tally <id> --output json' output!
            yes_count=$(echo "$tally_data" | jq -r '.yes_count // .yes // .tally.yes_count // .tally.yes // .tally_result.yes_count // .tally_result.yes // "0"' | tr -d '"')
            no_count=$(echo "$tally_data" | jq -r '.no_count // .no // .tally.no_count // .tally.no // .tally_result.no_count // .tally_result.no // "0"' | tr -d '"')
            abstain_count=$(echo "$tally_data" | jq -r '.abstain_count // .abstain // .tally.abstain_count // .tally.abstain // .tally_result.abstain_count // .tally_result.abstain // "0"' | tr -d '"')
            veto_count=$(echo "$tally_data" | jq -r '.no_with_veto_count // .no_with_veto // .tally.no_with_veto_count // .tally.no_with_veto // .tally_result.no_with_veto_count // .tally_result.no_with_veto // "0"' | tr -d '"')

            yes_count=${yes_count:-0}; no_count=${no_count:-0}; abstain_count=${abstain_count:-0}; veto_count=${veto_count:-0}
            echo "Counts for $proposal_id: Yes=$yes_count, No=$no_count, Abstain=$abstain_count, Veto=$veto_count"

            declare -A votes_map
            votes_map["yes"]=$yes_count; votes_map["no"]=$no_count; votes_map["abstain"]=$abstain_count; votes_map["no_with_veto"]=$veto_count
            majority_vote_option=""; max_votes=-1
            for option_key in "${!votes_map[@]}"; do
                current_option_votes_str=${votes_map[$option_key]}
                if [[ "$current_option_votes_str" =~ ^[0-9]+$ ]] && (( current_option_votes_str > max_votes )); then
                    max_votes=$current_option_votes_str; majority_vote_option=$option_key
                fi
            done
            if [[ -z "$majority_vote_option" || "$max_votes" -le 0 ]]; then
                echo "WARN: No clear majority or no votes for $proposal_id. Defaulting to ABSTAIN."
                majority_vote_option="abstain"
            fi

            echo "INFO: Determined majority vote for $proposal_id: $majority_vote_option"
            echo "INFO: Attempting to vote '$majority_vote_option' on proposal $proposal_id for $CLI_NAME..."

            # --- ACTUAL VOTE COMMAND SECTION (using arrays) ---
            VOTE_ARGS=(
                "$CLI_NAME" "tx" "gov" "vote" "$proposal_id" "$majority_vote_option"
                "--from" "$VOTERWALLET"
                "--chain-id" "$CHAIN_ID"
                "${NODE_COMMAND_PART_ARRAY[@]}"
                "--fees" "$FEES"
                "--keyring-backend" "test"
                "--gas" "$GAS"
                "--gas-adjustment" "$GAS_ADJUSTMENT"
                "-y" "--yes"
            )
            debug_echo "Vote command: ${VOTE_ARGS[@]}"

            vote_output=$("${VOTE_ARGS[@]}" 2>&1)
            VOTE_EXIT_STATUS=$?

            debug_echo "Vote command exit status: $VOTE_EXIT_STATUS"
            debug_echo "Vote command output: $vote_output"

            if [[ $VOTE_EXIT_STATUS -eq 0 ]]; then
                echo "SUCCESS: Vote command for '$majority_vote_option' on proposal ID $proposal_id submitted successfully to the node."
                proposals_voted_on_json=$(echo "$proposals_voted_on_json" | jq ". + {\"$proposal_id\": \"$(date -u -R)\"}")
                echo "INFO: Proposal $proposal_id marked as voted in the state."
            
            # Отправляем сообщение в Telegram
                TELEGRAM_MESSAGE="✅ Голос для $CLI_NAME
Пропозиция ID: $proposal_id
Выбранный голос: $majority_vote_option
Кошелек: $VOTERWALLET"
                send_telegram_message "$TELEGRAM_MESSAGE"
            
            else
                echo "ERROR: Failed to submit vote for proposal ID $proposal_id. Command exit status: $VOTE_EXIT_STATUS"
                echo "Full vote command error output: $vote_output"

                # Опционально: можно отправить сообщение об ошибке в TG
                # TELEGRAM_ERROR_MESSAGE="❌ Ошибка голосования для $CLI_NAME
                # Пропозиция ID: $proposal_id
                # Ошибка: $vote_output"
                # send_telegram_message "$TELEGRAM_ERROR_MESSAGE"
                
            fi
            # --- END OF ACTUAL VOTE COMMAND SECTION ---
        elif [[ $time_remaining_seconds -le 0 ]]; then
            echo "INFO: Voting period for proposal $proposal_id has already ended."
        else
            echo "INFO: Proposal $proposal_id is active, but voting window not yet reached (ends in $time_remaining_hours hours)."
        fi
    done
fi

# --- Save Updated Voted Proposals to State File ---
echo "INFO: Finalizing state. Voted proposals (JSON): $proposals_voted_on_json"
jq -n \
  --argjson pvo "$proposals_voted_on_json" \
  '{proposals_voted_on: $pvo}' > "$STATE_FILE"

echo "INFO: State saved to '$STATE_FILE'."
echo "INFO: ${CLI_NAME} Simplified Voting Script finished at $(date -u -R)"
