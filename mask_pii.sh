#!/bin/bash

# Exit on error
set -e

echo "checking for sandbox..."
# Check if current org is a sandbox
IS_SANDBOX=$(sf org display --json | grep '"isSandbox": true')

if [ -z "$IS_SANDBOX" ]; then
    echo "ERROR: The currently authorized org is NOT a sandbox or could not be determined."
    echo "This tool permanently modifies data. Please authorize a sandbox first."
    exit 1
fi

echo "Connected to a Sandbox. Proceeding..."

echo "Deploying PII Masking Utility to Org..."
sf project deploy start --ignore-conflicts

echo "Running PII Masking Job..."
sf apex run --file scripts/apex/run_masking.apex

echo "Done! Check Apex Jobs in Salesforce setup for progress."
