# Sourceable version of get_hi_station_catalog.R: the catalog build is a
# cache-aware function, and the table gains a latest_obs column — the
# timestamp of each station's most recent observation (HST text; NA if the
# station has none).
#
# As a library:
#   source("code/get_station_catalog_fn.R")
#   catalog <- get_station_catalog("HI")                  # read cache, or
#                                                         # build if absent
#   catalog <- get_station_catalog("HI", refresh = TRUE)  # rebuild + overwrite
#
# Arguments:
#   state     state code for the api.weather.gov catalog (default "HI")
#   latest    add two most-recent-data columns when building (default TRUE):
#               latest_obs_api  — timestamp of the station's newest
#                                 observation on the NWS API right now
#                                 (one API call per station, parallelized
#                                 on `cores`; NA = nothing in ~7-day store)
#               latest_obs_data — max datetime per station in YOUR collected
#                                 long-format data (from obs_file; NA = not
#                                 in that file)
#   cores     workers for the latest_obs_api lookup (default 2)
#   obs_file  long-format data file for latest_obs_data (default
#             data_out/hi_api_obs_long.csv at the PROJECT ROOT, i.e. the
#             parent of code/ — not the working directory; point at
#             data_out/hi_api_master.csv for the full record). If the
#             file is missing, latest_obs_data is NA with a warning.
#   dir       directory holding the catalog CSV (default: dataCatalog/ at
#             the project root — NOT the working directory — created if
#             missing; file is <state>_api_stations.csv inside it)
#   write_csv when building, save the catalog there (default TRUE)
#   refresh   TRUE = ignore any existing CSV, rebuild from the API and
#             overwrite so stations + both latest columns are current
#             (default FALSE: an existing CSV is read and returned as-is,
#             no API calls)
#
# As a script (always refreshes):
#   Rscript code/get_station_catalog_fn.R [state] [cores]  (defaults HI, 2)
#   -> dataCatalog/<state>_api_stations.csv (at the project root)

library(httr2)
library(purrr)
library(dplyr)
library(tibble)
library(readr)
library(parallel)

# directory this code file lives in (sourced -> the sourced file's dir;
# run via Rscript -> the script's dir; fallback -> working directory).
# The code lives in code/, so the project root -- holding data_out/ and
# dataCatalog/ -- is its parent.
.code_dir <- local({
  of <- NULL
  for (i in seq_len(sys.nframe())) {
    e <- sys.frame(i)
    if (!is.null(e$ofile)) of <- e$ofile
  }
  if (!is.null(of)) return(dirname(normalizePath(of, winslash = "/")))
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa)) return(dirname(normalizePath(sub("^--file=", "", fa[1]),
                                               winslash = "/")))
  getwd()
})
.data_dir <- dirname(.code_dir)   # project root (parent of code/)

get_station_catalog <- function(state = "HI", latest = TRUE, cores = 2,
                                obs_file = file.path(.data_dir, "data_out",
                                                     "hi_api_obs_long.csv"),
                                dir = file.path(.data_dir, "dataCatalog"),
                                write_csv = TRUE, refresh = FALSE,
                                ua = "R script (hcdp@hawaii.edu)") {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  csv_path <- file.path(dir, sprintf("%s_api_stations.csv", tolower(state)))

  # --- cached copy? -------------------------------------------------------
  if (!refresh && file.exists(csv_path)) {
    message("Reading existing catalog: ", csv_path,
            " (last modified ", format(file.mtime(csv_path)), ")")
    return(read.csv(csv_path))
  }

  # --- catalog listing (paginated) ----------------------------------------
  url <- sprintf("https://api.weather.gov/stations?state=%s&limit=500",
                 toupper(state))
  stations <- list()
  while (!is.null(url)) {
    message("Fetching ", url)
    page <- request(url) |>
      req_headers(`User-Agent` = ua, Accept = "application/geo+json") |>
      req_retry(max_tries = 3) |>
      req_perform() |>
      resp_body_json()
    if (length(page$features) == 0) break
    stations <- c(stations, page$features)
    url <- page$pagination$`next`
  }

  zone_id <- function(u) if (is.null(u)) NA_character_ else basename(u)
  catalog <- map_dfr(stations, function(f) {
    p <- f$properties
    tibble(
      station_id    = p$stationIdentifier,
      name          = p$name,
      latitude      = f$geometry$coordinates[[2]],
      longitude     = f$geometry$coordinates[[1]],
      elevation_m   = if (is.null(p$elevation$value)) NA_real_ else p$elevation$value,
      timezone      = p$timeZone,
      provider      = if (is.null(p$provider) || p$provider == "") NA_character_ else p$provider,
      sub_provider  = if (is.null(p$subProvider) || p$subProvider == "") NA_character_ else p$subProvider,
      forecast_zone = zone_id(p$forecast),
      county_zone   = zone_id(p$county),
      fire_zone     = zone_id(p$fireWeatherZone)
    )
  }) |>
    distinct(station_id, .keep_all = TRUE) |>
    arrange(station_id)
  message(nrow(catalog), " stations in catalog")

  if (latest) {
    # --- latest_obs_api: newest observation on the API right now ----------
    message("Fetching latest observation time per station on ", cores,
            " cores...")
    worker <- function(id, ua) {
      tryCatch({
        r <- httr2::request(sprintf(
               "https://api.weather.gov/stations/%s/observations?limit=1", id)) |>
          httr2::req_headers(`User-Agent` = ua,
                             Accept = "application/geo+json") |>
          httr2::req_retry(max_tries = 2) |>
          httr2::req_perform() |>
          httr2::resp_body_json()
        if (length(r$features) == 0) NA_character_
        else r$features[[1]]$properties$timestamp
      }, error = function(e) NA_character_)
    }
    if (cores > 1) {
      cl <- makeCluster(cores)
      raw <- parLapplyLB(cl, catalog$station_id, worker, ua = ua)
      stopCluster(cl)
    } else {
      raw <- lapply(catalog$station_id, worker, ua = ua)
    }
    ts_api <- unlist(raw)
    catalog$latest_obs_api <- format(
      as.POSIXct(sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", ts_api),
                 format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
      "%Y-%m-%d %H:%M:%S HST", tz = "Pacific/Honolulu"
    )
    message(sum(!is.na(catalog$latest_obs_api)),
            " stations have observations on the API")

    # --- latest_obs_data: newest datetime in collected long data ----------
    if (file.exists(obs_file)) {
      message("Deriving latest_obs_data from ", obs_file)
      obs <- read_csv(obs_file, col_types = cols_only(
        station_id = col_character(), datetime = col_character()),
        progress = FALSE)
      latest_tbl <- obs |>
        mutate(ts = as.POSIXct(sub(" HST$", "", datetime),
                               tz = "Pacific/Honolulu")) |>
        group_by(station_id) |>
        summarise(latest_obs_data = format(max(ts, na.rm = TRUE),
                                           "%Y-%m-%d %H:%M:%S HST",
                                           tz = "Pacific/Honolulu"),
                  .groups = "drop")
      catalog <- left_join(catalog, latest_tbl, by = "station_id")
      message(sum(!is.na(catalog$latest_obs_data)), " of ", nrow(catalog),
              " stations have data in ", obs_file)
    } else {
      warning("obs file not found (", obs_file,
              ") — latest_obs_data set to NA", call. = FALSE, immediate. = TRUE)
      catalog$latest_obs_data <- NA_character_
    }
  }

  # --- save ---------------------------------------------------------------
  if (write_csv) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    write.csv(catalog, csv_path, row.names = FALSE)
    message("Written to ", csv_path)
  }

  catalog
}

# --- run as a script -------------------------------------------------------
if (sys.nframe() == 0) {
  args  <- commandArgs(trailingOnly = TRUE)
  state <- if (length(args) >= 1) toupper(args[1]) else "HI"
  cores <- if (length(args) >= 2) as.integer(args[2]) else 2
  invisible(get_station_catalog(state, latest = TRUE, cores = cores,
                                refresh = TRUE))
}
