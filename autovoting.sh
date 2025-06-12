#!/bin/bash

# --- Configuration for Sommelier ---
# Name of the CLI binary for the chain (e.g., 'sommelier', 'junod', etc.)
CLI_NAME="YOUR_NODE_DAEMON" # <<< VERIFY this is the correct command for your node

# --- Node Configuration ---
# Set to true to use your synchronized local node (omits --node flag, CLI will use its default)
# Set to false to use the REMOTE_NODE_URL.
USE_LOCAL_NODE=true # <<< CHOOSE true OR false

# URL for the remote RPC node (only used if USE_LOCAL_NODE is false)
REMOTE_NODE_URL="https://your-sommelier-rpc-node-url:port" # <<< SET THIS IF USING A REMOTE NODE

# --- Chain & Voter Configuration ---
CHAIN_ID="YOUR_NETWORK_CHAIN-ID"                             # <<< VERIFY! Actual Chain ID for network
VOTER_KEY_NAME_OR_ADDRESS="votewallet" # Your key name or sommelier1... address
FEES="5000usomm"                                 # <<< VERIFY! Example fees in Sommelier's native token (e.g., usomm)

GAS="auto"
GAS_ADJUSTMENT="1.4"

STATE_FILE="${CLI_NAME}_state_simplified.json" # State file (stores only voted proposals)

# --- Script Behavior Configuration ---
# Limit for querying active proposals (user's command used 5)
ACTIVE_PROPOSALS_QUERY_LIMIT=10 # You can increase this if you expect more active proposals simultaneously
# If voting_end_time is within this many seconds, consider it "last day" for voting
VOTE_WINDOW_SECONDS=$((100 * 60 * 60)) # 24 hours

# --- Determine Node Command Flag ---
NODE_COMMAND_PART="" # Will be empty for local node, or --node <URL> for remote

if [ "$USE_LOCAL_NODE" = true ]; then
    echo "INFO: Script configured to use LOCAL node (via CLI default settings, usually tcp://localhost:26657)."
    # NODE_COMMAND_PART remains empty
else
    if [ -z "$REMOTE_NODE_URL" ] || [[ "$REMOTE_NODE_URL" == "https://your-sommelier-rpc-node-url:port" ]]; then
        echo "ERROR: USE_LOCAL_NODE is false, but REMOTE_NODE_URL is not set or is still the placeholder. Please configure it."
        exit 1
    fi
    NODE_COMMAND_PART="--node $REMOTE_NODE_URL"
    echo "INFO: Script configured to use REMOTE node: $REMOTE_NODE_URL"
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
echo "INFO: Voter Address/Key: $VOTER_KEY_NAME_OR_ADDRESS"
# Node usage message is now part of the NODE_COMMAND_PART setup
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
    echo "INFO: Loaded voted proposals (condensed): $proposals_voted_on_json"
else
    echo "INFO: '$STATE_FILE' not found. Initializing with empty voted list."
fi

# --- Fetch Active Proposals ---
echo "INFO: Fetching up to $ACTIVE_PROPOSALS_QUERY_LIMIT most recent active proposals..."
# Use $NODE_COMMAND_PART here
active_proposal_ids_json=$($CLI_NAME q gov proposals \
    $NODE_COMMAND_PART \
    --chain-id "$CHAIN_ID" \
    --reverse \
    --limit "$ACTIVE_PROPOSALS_QUERY_LIMIT" \
    --status "voting_period" \
    --output json 2>/dev/null | jq -c '[.proposals[].proposal_id // .proposals[].id | select(. != null)]') # <<< VERIFY JQ PATH for ID

if [[ $? -ne 0 || -z "$active_proposal_ids_json" || "$active_proposal_ids_json" == "[]" ]]; then
    # Also check if the result is an empty array "[]"
    echo "INFO: Failed to fetch active proposals, result was empty, or an error occurred. No proposals to process."
    # We don't exit here, just save the current (likely empty) voted state.
else
    # Only try to map if active_proposal_ids_json is not empty and not just "[]"
    mapfile -t active_proposal_ids < <(echo "$active_proposal_ids_json" | jq -r '.[]')
fi


if [[ -z "$active_proposal_ids_json" || "$active_proposal_ids_json" == "[]" ]]; then
    # This check is because mapfile might behave unexpectedly with empty input on some systems,
    # or if jq outputs 'null' which becomes an empty string for mapfile.
    # Forcing active_proposal_ids to be definitely empty if json was empty or "[]".
    active_proposal_ids=()
fi


echo "INFO: Found ${#active_proposal_ids[@]} active proposal(s) directly from query."
echo "------------------------------------------------------"

if [[ ${#active_proposal_ids[@]} -eq 0 ]]; then
    echo "INFO: No active proposals found to process."
else
    NOW_EPOCH=$(current_epoch)
    for proposal_id in "${active_proposal_ids[@]}"; do
        echo ""
        echo "Processing Active Sommelier Proposal ID: $proposal_id"

        if echo "$proposals_voted_on_json" | jq -e ".\"$proposal_id\"" > /dev/null; then
            echo "INFO: Already voted on proposal $proposal_id based on state file. Skipping."
            continue
        fi

        # Fetch full proposal details to get voting_end_time
        # Use $NODE_COMMAND_PART here
        proposal_data=$($CLI_NAME q gov proposal "$proposal_id" $NODE_COMMAND_PART --chain-id "$CHAIN_ID" --output json 2>/dev/null)
        if [[ $? -ne 0 || -z "$proposal_data" ]]; then
            echo "ERROR: Failed to fetch details for proposal $proposal_id. Skipping."
            continue
        fi

        # IMPORTANT: Verify JQ path for .voting_end_time for Sommelier
        voting_end_time_iso=$(echo "$proposal_data" | jq -r '.voting_end_time') # <<< VERIFY JQ PATH for .voting_end_time
        VOTING_END_EPOCH=$(iso_to_epoch "$voting_end_time_iso")

        if [[ -z "$VOTING_END_EPOCH" ]]; then echo "ERROR: Could not parse voting_end_time for $proposal_id ('$voting_end_time_iso'). Skipping."; continue; fi

        time_remaining_seconds=$((VOTING_END_EPOCH - NOW_EPOCH))
        time_remaining_hours=$(awk "BEGIN {printf \"%.2f\", $time_remaining_seconds / 3600}")
        echo "Voting End Time: $voting_end_time_iso | Time Remaining: $time_remaining_hours hours"

        if [[ $time_remaining_seconds -le $VOTE_WINDOW_SECONDS && $time_remaining_seconds -gt 0 ]]; then
            echo "INFO: Proposal $proposal_id is within the voting window. Fetching tally..."

            # Use $NODE_COMMAND_PART here
            tally_data=$($CLI_NAME q gov tally "$proposal_id" $NODE_COMMAND_PART --chain-id "$CHAIN_ID" --output json 2>/dev/null)
            if [[ $? -ne 0 || -z "$tally_data" ]]; then echo "ERROR: Failed to fetch tally for $proposal_id. Skipping."; continue; fi

            # IMPORTANT: VERIFY THESE JQ PATHS with actual 'YOUR_DAEMON q gov tally <id> --output json' output!
            yes_count=$(echo "$tally_data" | jq -r '.yes_count // .yes // .tally.yes_count // .tally.yes // "0"' | tr -d '"') # <<< VERIFY JQ PATH
            no_count=$(echo "$tally_data" | jq -r '.no_count // .no // .tally.no_count // .tally.no // "0"' | tr -d '"') # <<< VERIFY JQ PATH
            abstain_count=$(echo "$tally_data" | jq -r '.abstain_count // .abstain // .tally.abstain_count // .tally.abstain // "0"' | tr -d '"') # <<< VERIFY JQ PATH
            veto_count=$(echo "$tally_data" | jq -r '.no_with_veto_count // .no_with_veto // .tally.no_with_veto_count // .tally.no_with_veto // "0"' | tr -d '"') # <<< VERIFY JQ PATH

            yes_count=${yes_count:-0}; no_count=${no_count:-0}; abstain_count=${abstain_count:-0}; veto_count=${veto_count:-0}
            echo "Counts for $proposal_id: Yes=$yes_count, No=$no_count, Abstain=$abstain_count, Veto=$veto_count"

            declare -A votes_map
            votes_map["yes"]=$yes_count; votes_map["no"]=$no_count; votes_map["abstain"]=$abstain_count; votes_map["no_with_veto"]=$veto_count
            majority_vote_option=""; max_votes=-1
            for option_key in "${!votes_map[@]}"; do
                current_option_votes_str=${votes_map[$option_key]}
                if [[ "$current_option_votes_str" =~ ^[0-9]+$ && "$current_option_votes_str" -gt "$max_votes" ]]; then # Ensure numeric comparison
                    max_votes=$current_option_votes_str; majority_vote_option=$option_key
                fi
            done
            if [[ -z "$majority_vote_option" || "$max_votes" == "0" || "$max_votes" == "-1" ]]; then # Also check if max_votes is literally "0" or not set
                echo "WARN: No clear majority or no votes for $proposal_id. Defaulting to ABSTAIN."
                majority_vote_option="abstain"
            fi

            echo "INFO: Determined majority vote for $proposal_id: $majority_vote_option"
            echo "INFO: Attempting to vote '$majority_vote_option' on proposal $proposal_id for Sommelier..."

            # --- ACTUAL VOTE COMMAND SECTION for Sommelier ---
            # CAUTION: Ensure all variables are correct. Test WITHOUT '-y --yes' first.
            # Use $NODE_COMMAND_PART here
            $CLI_NAME tx gov vote "$proposal_id" "$majority_vote_option" \
                --from "$VOTER_KEY_NAME_OR_ADDRESS" \
                --chain-id "$CHAIN_ID" \
                $NODE_COMMAND_PART \
                --fees "$FEES" \
		--keyring-backend test \
                --gas "$GAS" --gas-adjustment "$GAS_ADJUSTMENT" \
                -y --yes # REMOVE '-y --yes' for initial manual confirmation of transaction during tests

            VOTE_EXIT_STATUS=$?
            if [[ $VOTE_EXIT_STATUS -eq 0 ]]; then
                echo "SUCCESS: Vote command for '$majority_vote_option' on proposal ID $proposal_id submitted successfully to the node (Sommelier)."
                proposals_voted_on_json=$(echo "$proposals_voted_on_json" | jq ". + {\"$proposal_id\": \"$(date -u -R)\"}")
                echo "INFO: Proposal $proposal_id marked as voted in the state."
            else
                echo "ERROR: Failed to submit vote for proposal ID $proposal_id (Sommelier). Command exit status: $VOTE_EXIT_STATUS"
            fi
            # --- END OF ACTUAL VOTE COMMAND SECTION ---
        elif [[ $time_remaining_seconds -le 0 ]]; then
            echo "INFO: Voting period for proposal $proposal_id (Sommelier) has already ended."
        else
            echo "INFO: Proposal $proposal_id (Sommelier) is active, but voting window not yet reached (ends in $time_remaining_hours hours)."
        fi
    done
fi

# --- Save Updated Voted Proposals to State File ---
echo "INFO: Finalizing state for Sommelier. Voted proposals (JSON): $proposals_voted_on_json"
# This simplified version only stores proposals_voted_on in the state file.
jq -n \
  --argjson pvo "$proposals_voted_on_json" \
  '{proposals_voted_on: $pvo}' > "$STATE_FILE"

echo "INFO: State saved to '$STATE_FILE'."
echo "INFO: Sommelier Simplified Voting Script finished at $(date -u -R)"
