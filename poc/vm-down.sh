#!/bin/bash
# Destroy the POC VM.
set -euo pipefail
VM="${POC_VM:-pi-jail-poc}"
incus delete -f "$VM"
echo "deleted $VM"
