#!/bin/bash

set -euo pipefail

echo "[task.sh] [1/2] Starting Execution."
export TZ="HST"
source /workspace/envs/prod.env

echo "[task.sh] [2/2] Running workflow."
Rscript /workspace/code/get_hi_api_obs_all.R
Rscript /workspace/code/append_hi_api_master.R

echo "[task.sh] All done!"