#!/bin/bash

cd /home/pi

# Check if rtl_433 is installed
if ! command -v rtl_433 &> /dev/null
then
    echo "rtl_433 could not be found, please install it first."
    exit 1
fi

# Check if rtl-sdr device is available
if ! rtl_test -t &> /dev/null
then
    echo "RTL-SDR device not found. Please connect your RTL-SDR device."
    exit 1
fi

# Set the config file and output file names
CONFIG_FILE="rtl_reader_config.txt"  # Updated config file name
OUTPUT_FILE="rtl_433_output.txt"  # Updated output file name

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file ($CONFIG_FILE) not found!"
    exit 1
fi

# MQTT Broker Configuration
MQTT_BROKER="192.168.2.23"  # Use your specified MQTT broker address
MQTT_PORT="1883"            # Default MQTT port

# Optionally, allow passing of MQTT credentials via environment variables
MQTT_USER=${MQTT_USER:-"user"}  # Default to empty if not provided
MQTT_PASS=${MQTT_PASS:-"passwd"}  # Default to empty if not provided

# Ensure the output file exists and is empty (clear the file but don't overwrite the file itself)
> $OUTPUT_FILE

# Declare arrays to store configuration values
declare -a FREQ_MHZ_ARRAY
declare -a DURATION_ARRAY
declare -a TARGET_IDS_ARRAY
declare -a MQTT_TOPIC_ARRAY

# Read the config file line by line
while IFS= read -r line; do
    # Skip empty lines or comment lines
    if [[ -z "$line" || "$line" == \#* ]]; then
        continue
    fi

    # Parse frequency in MHz (no need to strip "M"), duration, target IDs, and MQTT topic
    FREQ_MHZ=$(echo $line | cut -d' ' -f1)  # Keep frequency in MHz (e.g., 315.02M)
    DURATION=$(echo $line | cut -d' ' -f2)
    TARGET_IDS=$(echo $line | cut -d' ' -f3- | cut -d'"' -f2)
    MQTT_TOPIC=$(echo $line | awk '{print $NF}')

    # Store values in the arrays
    FREQ_MHZ_ARRAY+=("$FREQ_MHZ")
    DURATION_ARRAY+=("$DURATION")
    TARGET_IDS_ARRAY+=("$TARGET_IDS")
    MQTT_TOPIC_ARRAY+=("$MQTT_TOPIC")

done < "$CONFIG_FILE"

# Function to handle cleanup on Ctrl+C
cleanup() {
    echo "Caught SIGINT (Ctrl+C). Exiting gracefully..."
    # Kill any running rtl_433 processes
    if [ ! -z "$RTL_433_PID" ]; then
        kill $RTL_433_PID
    fi
    exit 1
}

# Trap Ctrl+C (SIGINT) to cleanly exit the script
trap cleanup SIGINT

# Loop through each frequency entry in the arrays
for i in "${!FREQ_MHZ_ARRAY[@]}"; do
    FREQ_MHZ="${FREQ_MHZ_ARRAY[$i]}"
    DURATION="${DURATION_ARRAY[$i]}"
    TARGET_IDS="${TARGET_IDS_ARRAY[$i]}"
    MQTT_TOPIC="${MQTT_TOPIC_ARRAY[$i]}"

    # Convert the target IDs into an array for easier comparison later
    TARGET_IDS_ARRAY_SPLIT=($TARGET_IDS)
    NUM_TARGETS=${#TARGET_IDS_ARRAY_SPLIT[@]}

    # Print header for this frequency block in the output file
    echo "Starting capture for frequency $FREQ_MHZ with duration $DURATION seconds (looking for IDs: $TARGET_IDS)..." >> $OUTPUT_FILE
    echo "----------------------------------------" >> $OUTPUT_FILE

    # Debugging message - print out the frequency and duration to the console
    echo "Debug: Capturing data for frequency $FREQ_MHZ and duration $DURATION seconds."

    # Flag to stop once all of the target IDs are found
    TARGETS_FOUND=0

    # Run rtl_433 directly and capture the output
    rtl_433 -f $FREQ_MHZ -F json -T $DURATION | while read -r line; do
        # Save decoded output to file
        echo "$line" >> $OUTPUT_FILE

        # Debugging message - print out the decoded line
        echo "Debug: Decoded data: $line"

        # Extract the id from the JSON using jq (note: ID is an integer)
        ID=$(echo "$line" | jq -r '.id')

        # Check if the id matches any of the target IDs
        for target_id in "${TARGET_IDS_ARRAY_SPLIT[@]}"; do
            # Compare ID as a string to account for non-integer IDs
            if [ "$ID" == "$target_id" ]; then
                # Increment the count of found IDs
                TARGETS_FOUND=$((TARGETS_FOUND + 1))
                echo "Found target ID $target_id at frequency $FREQ_MHZ." >> $OUTPUT_FILE
                #echo "Debug: Found matching target ID $target_id"  # Debugging message
                #echo "Debug: Publishing topic $MQTT_TOPIC and line $line"
                # if [[ "RTL315" == *"$MQTT_TOPIC"* ]] ; then
                #     MQTT_TOPIC="RTL315"'/'"$target_id"
                # else
                #     MQTT_TOPIC="$MQTT_TOPIC"'/'"$target_id"
                # fi
                MQTT_PUBLISH_TOPIC="$MQTT_TOPIC"'/'"$target_id"
                echo "Debug: Publishing topic $MQTT_PUBLISH_TOPIC and line $line"

                # Publish the captured line to MQTT using the dynamic topic
                mosquitto_pub -h $MQTT_BROKER -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "$MQTT_PUBLISH_TOPIC" -r -m "$line"
                MQTT_PUBLISH_TOPIC=''

                # Debugging message - print out the ID and the topic
                echo "Debug: Published to MQTT topic $MQTT_TOPIC with message: $line"
                break  # Exit the loop once a target ID is found
            fi
        done

        # If all IDs are found, exit the inner loop to move to the next frequency
        if [ "$TARGETS_FOUND" -eq "$NUM_TARGETS" ]; then
            echo "All target IDs found at frequency $FREQ_MHZ." >> $OUTPUT_FILE
            echo "Debug: All target IDs found at frequency $FREQ_MHZ."  # Debugging message
            break  # Exit the while loop and move to the next frequency
        fi
    done

    # If time expires before all IDs are found, print a message
    if [ "$TARGETS_FOUND" -lt "$NUM_TARGETS" ]; then
        echo "Time expired at frequency $FREQ_MHZ before all target IDs were found. Found $TARGETS_FOUND out of $NUM_TARGETS." >> $OUTPUT_FILE
        echo "Debug: Time expired before all target IDs were found at frequency $FREQ_MHZ."  # Debugging message
    fi

    # Pause for 1 second between captures (optional)
    sleep 1
done

# Final message after all frequencies have been processed
echo "Packet capture completed for all frequencies. Decoded output is written to $OUTPUT_FILE."
echo "Debug: Packet capture completed. Output saved to $OUTPUT_FILE."  # Debugging message
