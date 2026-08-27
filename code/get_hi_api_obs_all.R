# Catalog-driven incremental pull of api.weather.gov observations for all
# Hawaii stations in four groups — airports (ICAO PHxx/PMDY), RAWS/MECO-style
# (NNNHI / NNNHE), H1 hydro gauges (xxxxH1), and buoys (5-digit) — into
# one long-format table:
#   station_id | datetime | variable | value | unit | provider
#
# 'provider' is the API's network attribution as provider/subProvider
# (e.g. "MesoWest/HECO", "HADS", "ASOS"). 'datetime' is Hawaii local
# time text ending in "HST" (e.g. "2026-07-24 15:00:00 HST").
#
# How it decides what to fetch (via the station catalog in dataCatalog/):
#   1. Loads the catalog with get_station_catalog() — reads
#      dataCatalog/hi_api_stations.csv if present, otherwise builds and
#      writes it (first run).
#   2. Keeps stations whose latest_obs_api is within the last 7 days
#      (alive on the API).
#   3. Fetches each station from its latest_obs_data to now, with a
#      12-hour minimum window — e.g. 3 days behind -> fetch 3 days;
#      only 4 hours behind -> fetch 12 hours. No latest_obs_data at all
#      (new station) -> fetch the full 7-day retention.
#   4. After writing data_out/hi_api_obs_long.csv, refreshes the catalog
#      (refresh = TRUE) so the file reflects this fetch.
#
# Usage:  Rscript code/get_hi_api_obs_all.R
#         Runs on 1 core -- n_cores is pinned below and any argument is
#         ignored. Restore the commented-out expression there to re-enable
#         the [cores] argument.
# Output: data_out/hi_api_obs_long.csv, dataCatalog/hi_api_stations.csv
#         (both are created at the project root -- the parent of code/ --
#         NOT in the working directory)

# code/ directory this script lives in (Rscript --file=...; falls back to
# the working directory if the script is sourced interactively). The
# project root -- where the data directories live -- is its parent.

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")
codeDir <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(fa))
    dirname(normalizePath(sub("^--file=", "", fa[1]), winslash = "/"))
  else getwd()
})
mainDir <- dirname(codeDir)

# loads httr2/dplyr/purrr/tibble/readr/parallel and get_station_catalog()
source(file.path(codeDir, "get_station_catalog_fn.R"))

# data lives at the project root, not in the working directory
out_dir  <- file.path(mainDir, "data_out")
obs_path <- file.path(out_dir, "hi_api_obs_long.csv")

args    <- commandArgs(trailingOnly = TRUE)
n_cores <- 1 # OFF: if (length(args) >= 1) as.integer(args[1]) else 2

alive_window <- 7 * 24 * 3600    # station considered alive if API has data
min_fetch    <- 12 * 3600        # never fetch less than this
max_fetch    <- 7 * 24 * 3600    # API retention; also the new-station window
max_catalog_age <- 24 * 3600     # rebuild the catalog once it is older than this

ua       <- "R script (hcdp@hawaii.edu)"
end_time <- Sys.time()
iso_utc  <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

num_vars <- c(
  "temperature", "dewpoint", "relativeHumidity",
  "windDirection", "windSpeed", "windGust",
  "barometricPressure", "seaLevelPressure", "visibility",
  "maxTemperatureLast24Hours", "minTemperatureLast24Hours",
  "precipitationLastHour", "precipitationLast3Hours", "precipitationLast6Hours",
  "windChill", "heatIndex"
)

# used by both the catalog age check below and target selection
parse_hst <- function(x) as.POSIXct(sub(" HST$", "", x), tz = "Pacific/Honolulu")

# --- 1. Catalog: read cache, rebuilding it if stale ------------------------
# (lives in dataCatalog/ at the project root — the function's default)
#
# A stale catalog is fatal on its own: every latest_obs_api would fall
# outside alive_window, no station would qualify, and the end-of-run refresh
# that would have fixed it is never reached. So check age up front, two ways
# — they catch different failures and either one forces a rebuild:
#   file age  — nobody has run this lately
#   data age  — the file was copied/restored/touched, so its mtime lies
state       <- "HI"
catalog_csv <- file.path(mainDir, "dataCatalog",
                         sprintf("%s_api_stations.csv", tolower(state)))

catalog_age <- function(path) {
  if (!file.exists(path)) return(Inf)
  file_age <- as.numeric(Sys.time() - file.mtime(path), units = "secs")
  ts <- suppressWarnings(parse_hst(read.csv(path)$latest_obs_api))
  # no usable timestamps (column absent, or an API outage during the last
  # rebuild left it all NA) counts as stale so the next run retries
  data_age <- if (!length(ts) || all(is.na(ts))) Inf else
    as.numeric(Sys.time() - max(ts, na.rm = TRUE), units = "secs")
  max(file_age, data_age)
}

age   <- catalog_age(catalog_csv)
stale <- age > max_catalog_age
if (stale) say(sprintf(
  "Catalog %s (age %s, limit %.0f h) — rebuilding from the API",
  if (file.exists(catalog_csv)) "is stale" else "not found",
  if (is.finite(age)) sprintf("%.1f h", age / 3600) else "unknown",
  max_catalog_age / 3600))
catalog <- get_station_catalog(state, cores = n_cores, refresh = stale)

# --- 2. Target selection ---------------------------------------------------
classify <- function(id) {
  if (grepl("^P[HM][A-Z0-9]{2}$", id)) "airport"
  else if (grepl("^[0-9]{3}H[IE]$", id)) "raws_meco"
  else if (grepl("H1$", id))             "h1_gauge"
  else if (grepl("^[0-9]{5}$", id))      "buoy"
  else NA_character_
}
select_targets <- function(catalog) {
  catalog |>
    mutate(
      group    = vapply(station_id, classify, character(1)),
      provider = ifelse(is.na(provider), NA_character_,
                        ifelse(is.na(sub_provider), provider,
                               paste(provider, sub_provider, sep = "/"))),
      api_ts   = parse_hst(latest_obs_api),
      data_ts  = parse_hst(latest_obs_data)
    ) |>
    filter(!is.na(group), !is.na(api_ts),
           api_ts >= end_time - alive_window) |>
    mutate(
      fetch_start = pmin(data_ts, end_time - min_fetch),
      fetch_start = if_else(is.na(fetch_start), end_time - max_fetch, fetch_start),
      fetch_start = pmax(fetch_start, end_time - max_fetch)
    )
}
targets <- select_targets(catalog)

# Self-heal: a cached catalog that yields nothing is stale in a way the age
# checks missed. Rebuild once and retry rather than failing. Never runs in
# normal operation, and cannot loop — stale is TRUE on the retry.
if (nrow(targets) == 0 && !stale) {
  say("No live stations in the cached catalog — forcing a rebuild and retrying")
  catalog <- get_station_catalog(state, cores = n_cores, refresh = TRUE)
  stale   <- TRUE
  targets <- select_targets(catalog)
}

# Fail here rather than 100 lines on: with no targets the fetch below spins up
# a cluster over an empty set and dies with a misleading "No observations".
if (nrow(targets) == 0)
  stop("No stations alive on the API after rebuilding the catalog (",
       nrow(catalog), " stations listed) — the API is likely down or ",
       "returning nothing within the last ", alive_window / 86400, " days.")

say(sprintf(
  "%d of %d catalog stations alive on the API; fetch windows %.1f to %.1f hrs",
  nrow(targets), nrow(catalog),
  min(as.numeric(end_time - targets$fetch_start, units = "hours")),
  max(as.numeric(end_time - targets$fetch_start, units = "hours"))
))

# --- 3. Fetch observations -------------------------------------------------
parse_feats <- function(fs, station_id, provider) {
  map_dfr(fs, function(f) {
    p <- f$properties
    vals <- map_dbl(num_vars, function(v) {
      x <- p[[v]]$value
      if (is.null(x)) NA_real_ else as.numeric(x)
    })
    keep <- !is.na(vals)
    if (!any(keep)) return(NULL)
    tibble(
      station_id,
      datetime = p$timestamp,
      variable = num_vars[keep],
      value    = vals[keep],
      unit     = map_chr(num_vars[keep], function(v) {
        u <- p[[v]]$unitCode
        if (is.null(u)) NA_character_ else sub("^wmoUnit:", "", u)
      }),
      provider
    )
  })
}

obs_url <- function(id) sprintf("https://api.weather.gov/stations/%s/observations", id)

get_window <- function(id, s, e) {
  request(obs_url(id)) |>
    req_url_query(start = iso_utc(s), end = iso_utc(e), limit = 500) |>
    req_headers(`User-Agent` = ua, Accept = "application/geo+json") |>
    req_retry(max_tries = 3) |>
    req_perform() |>
    resp_body_json() |>
    pluck("features")
}

fetch_station <- function(id, provider, start) {
  fs <- get_window(id, start, end_time)
  if (length(fs) == 500) {
    # hit the cap — refetch in daily windows to get everything
    starts <- seq(start, end_time, by = "1 day")
    fs <- flatten(map(starts, function(s) {
      e <- min(s + 24 * 3600, end_time)
      if (e <= s) list() else get_window(id, s, e)
    }))
  }
  parse_feats(fs, id, provider)
}

say("Fetching observations on ", n_cores, " cores...")
cl <- makeCluster(n_cores)
invisible(clusterEvalQ(cl, { suppressPackageStartupMessages({ library(httr2)
    library(purrr); library(tibble) }) }))
clusterExport(cl, c("num_vars", "ua", "iso_utc", "end_time",
                    "parse_feats", "obs_url", "get_window", "fetch_station"))

# batches only exist to print progress; parLapplyLB load-balances within each
batches <- split(seq_len(nrow(targets)),
                 ceiling(seq_len(nrow(targets)) / (n_cores * 10)))
results <- list()
for (b in batches) {
  res <- parLapplyLB(cl, b, function(i, ids, provs, starts) {
    tryCatch(fetch_station(ids[i], provs[i], starts[i]),
             error = function(e) paste0(ids[i], ": ", conditionMessage(e)))
  }, ids = targets$station_id, provs = targets$provider,
     starts = targets$fetch_start)
  results <- c(results, res)
  say(sprintf("...%d/%d stations", max(b), nrow(targets)))
}
stopCluster(cl)

is_err <- vapply(results, is.character, logical(1))
for (e in unlist(results[is_err])) warning(e, call. = FALSE, immediate. = TRUE)
obs_long <- bind_rows(results[!is_err])

if (nrow(obs_long) == 0) stop("No observations returned.")

# --- 4. Finalize -----------------------------------------------------------
# convert timestamps to Hawaii local time, written as text ending in "HST"
obs_long <- obs_long |>
  mutate(datetime = format(
    as.POSIXct(sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", datetime),
               format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
    "%Y-%m-%d %H:%M:%S HST", tz = "Pacific/Honolulu"
  )) |>
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime, variable)

sum_by_prov <- obs_long |>
  group_by(provider) |>
  summarise(stations = n_distinct(station_id), rows = n())
say(paste(capture.output(print(as.data.frame(sum_by_prov))), collapse = "\n"))
say(sprintf("TOTAL: %d rows, %d stations reporting (of %d targeted)",
                nrow(obs_long), n_distinct(obs_long$station_id), nrow(targets)))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
write.csv(obs_long, obs_path, row.names = FALSE)
say("Written to ", obs_path)

# --- 5. Refresh the catalog so it reflects this fetch ----------------------
invisible(get_station_catalog("HI", cores = n_cores, refresh = TRUE))
