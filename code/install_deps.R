# One-time dependency installer for this toolkit. Run once at deployment:
#   Rscript code/install_deps.R
#
# Checks every package each workflow needs, installs whatever is missing
# from CRAN, and reports a per-workflow readiness summary. Safe to re-run
# (already-installed packages are skipped). 'parallel' ships with R itself
# so it is not listed.

workflow_deps <- list(
  "RR5 rainfall     (get_rr5_archive.R / append_rr5_master.R)" =
    c("httr2", "dplyr", "purrr", "tibble"),
  "All-networks API (code/get_hi_api_obs_all.R / code/append_hi_api_master.R)" =
    c("httr2", "dplyr", "purrr", "tibble", "readr"),
  "Station catalog  (get_hi_station_catalog.R / append_catalog_master.R)" =
    c("httr2", "dplyr", "purrr", "tibble"),
  "IEM DCP          (get_iem_dcp.R)" =
    c("httr2", "dplyr", "tidyr", "purrr", "tibble", "readr"),
  "Airport METAR    (get_nws_obs.R)" =
    c("httr2", "dplyr", "tidyr", "purrr", "tibble")
)

needed    <- sort(unique(unlist(workflow_deps)))
installed <- rownames(installed.packages())
missing   <- setdiff(needed, installed)

if (length(missing) == 0) {
  message("All ", length(needed), " required packages already installed: ",
          paste(needed, collapse = ", "))
} else {
  message("Installing ", length(missing), " missing package(s): ",
          paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
}

# --- per-workflow readiness report -----------------------------------------
installed <- rownames(installed.packages())   # refresh after install
message("\nWorkflow readiness:")
ok_all <- TRUE
for (wf in names(workflow_deps)) {
  still_missing <- setdiff(workflow_deps[[wf]], installed)
  if (length(still_missing) == 0) {
    message("  [OK]      ", wf)
  } else {
    ok_all <- FALSE
    message("  [MISSING] ", wf, " — needs: ",
            paste(still_missing, collapse = ", "))
  }
}
if (!ok_all) stop("Some packages failed to install — see above.")
message("\nAll workflows ready. R ", R.version$major, ".", R.version$minor,
        " at ", R.home())
