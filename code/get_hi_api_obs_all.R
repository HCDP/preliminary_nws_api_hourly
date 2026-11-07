# Catalog-driven incremental pull of api.weather.gov observations for all
# Hawaii stations in six groups — airports (ICAO PHxx/PMDY), RAWS/MECO-style
# (NNNHI / NNNHE), RAWS fire-weather (TXNNN), H1 hydro gauges (xxxxH1),
# HADS coastal (PNN), and buoys (5-digit) — and writes them to the HCDP
# database's nws_api tables through the acquisition API
# (code/hcdp_db_acquisition.R):
#   data             station_id | timestamp | variable | value
#   variableMetadata variable | unit
#   stationMetadata  station_id | station_name | data_provider | skn | lat | lng
#
# 'data_provider' is the API's network attribution as provider/subProvider
# (e.g. "MesoWest/HECO", "HADS", "ASOS"). 'timestamp' is UTC ISO 8601
# text (e.g. "2026-07-24T01:00:00Z"); nothing is converted to local time.
#
# How it decides what to fetch:
#   1. Loads the station catalog with get_station_catalog() — reads
#      dataCatalog/hi_api_stations.csv if present, otherwise builds and
#      writes it (first run).
#   2. Keeps stations whose latest_obs_api is within the last 7 days
#      (alive on the API).
#   3. Asks the HCDP database for each live station's newest timestamp
#      (hcdp_latest_obs()) and fetches from there to now, with a 12-hour
#      minimum window — e.g. 3 days behind -> fetch 3 days; only 4 hours
#      behind -> fetch 12 hours. Not in the database at all (new station)
#      -> fetch the full 7-day retention.
#   4. Writes to the database (hcdp_write()): observations and station
#      metadata are upserted, so a re-fetched value replaces the stored one;
#      variable metadata is insert-only. Each station's skn comes from the
#      HCDP master station list, matched on NWS.id exactly as the MADIS
#      workflow does (null where there is no unambiguous match).
#   5. Refreshes the catalog (refresh = TRUE) so latest_obs_api is current.
#
# Usage:  Rscript code/get_hi_api_obs_all.R
#         Runs on 1 core -- n_cores is pinned below and any argument is
#         ignored. Restore the commented-out expression there to re-enable
#         the [cores] argument.
# Output: the HCDP database (nothing is written locally except the catalog,
#         $NWSAPI_DATA_CATALOG/hi_api_stations.csv, default dataCatalog/
#         under $NWSAPI_PROJECT_ROOT, which is REQUIRED in the environment --
#         see the block below). Needs the HCDP token in token.env at the
#         project root, or the file named by $HCDP_TOKEN_FILE.

# progress goes to stdout via say(), not message()/stderr, so the cron job's
# .err log collects only real problems (warnings and errors). say() matches
# message() semantics: arguments pasted with no separator, newline appended.
say <- function(...) cat(..., "\n", sep = "")
# --- directories from the environment --------------------------------------
# This workflow takes its paths from the environment rather than deriving
# them from the script's own location. NWSAPI_PROJECT_ROOT is REQUIRED; the
# directories under it can each be redirected individually. An unset root is
# a hard error on purpose -- the old behaviour fell back to the script's
# parent (or, when sourced, the working directory), which could silently
# write a whole run into the wrong tree.
#
#   NWSAPI_PROJECT_ROOT        required   project root
#   NWSAPI_CODE_DIR            optional   default $NWSAPI_PROJECT_ROOT/code
#   NWSAPI_DATA_OUT            optional   default $NWSAPI_PROJECT_ROOT/data_out
#   NWSAPI_DATA_CATALOG        optional   default $NWSAPI_PROJECT_ROOT/dataCatalog
#
# See envs/nwsapi.env for a ready-to-source file, and the cron file for how
# the scheduled job loads it.
.env_dir <- function(var, default = NULL, must_exist = TRUE) {
  v <- Sys.getenv(var)
  if (!nzchar(v)) {
    if (is.null(default))
      stop(var, " is not set. This workflow requires its directories to come ",
           "from the environment -- export ", var, " (see envs/nwsapi.env) ",
           "before running.", call. = FALSE)
    v <- default
  }
  v <- path.expand(v)
  if (must_exist && !dir.exists(v))
    stop(var, " is set to a directory that does not exist: ", v, call. = FALSE)
  normalizePath(v, winslash = "/", mustWork = FALSE)
}
mainDir     <- .env_dir("NWSAPI_PROJECT_ROOT")
codeDir     <- .env_dir("NWSAPI_CODE_DIR",     file.path(mainDir, "code"))
catalog_dir <- .env_dir("NWSAPI_DATA_CATALOG", file.path(mainDir, "dataCatalog"),
                        must_exist = FALSE)

# loads httr2/dplyr/purrr/tibble/readr/parallel, get_station_catalog(), and
# the UTC timestamp helpers iso_utc()/parse_utc(); it resolves the same
# variables independently
source(file.path(codeDir, "get_station_catalog_fn.R"))
# the HCDP database client: hcdp_latest_obs(), hcdp_write(), and api_url.
# Reads the token now, so a missing token.env fails here, before any fetching.
source(file.path(codeDir, "hcdp_db_acquisition.R"))

# --- HCDP master station list, for skn --------------------------------------
# Same source and match as the MADIS workflow (madis_hourly_aqs.py): a
# station's skn is the master list's SKN on the row whose NWS.id equals its
# station_id. An NWS.id listed more than once is ambiguous and, like a
# station not in the list, gets a null skn. Loaded before anything is fetched
# so an unreachable list stops the run early: station metadata is upserted,
# so falling back to null skns would wipe the stored ones.
master_meta_url <- Sys.getenv("HCDP_MASTER_META_URL", paste0(
  "https://raw.githubusercontent.com/ikewai/hawaii_wx_station_mgmt_container/",
  "main/Hawaii_Master_Station_Meta.csv"))
master_meta <- request(master_meta_url) |>
  req_retry(max_tries = 3, retry_on_failure = TRUE) |>
  req_perform() |>
  resp_body_string()
master_meta <- read.csv(text = master_meta, stringsAsFactors = FALSE)
if (!all(c("SKN", "NWS.id") %in% names(master_meta)))
  stop("master station list (", master_meta_url, ") has no SKN / NWS.id columns",
       call. = FALSE)
master_nws  <- master_meta$NWS.id[!is.na(master_meta$NWS.id) & master_meta$NWS.id != ""]
skn_dupes   <- unique(master_nws[duplicated(master_nws)])
skn_lookup  <- master_meta |>
  filter(NWS.id %in% master_nws, !NWS.id %in% skn_dupes) |>
  transmute(station_id = NWS.id, skn = SKN)
say("Master station list: ", nrow(skn_lookup), " unambiguous NWS.id -> SKN entries")

args    <- commandArgs(trailingOnly = TRUE)
n_cores <- 1 # OFF: if (length(args) >= 1) as.integer(args[1]) else 2

alive_window <- 7 * 24 * 3600    # station considered alive if API has data
min_fetch    <- 12 * 3600        # never fetch less than this
max_fetch    <- 7 * 24 * 3600    # API retention; also the new-station window
max_catalog_age <- 24 * 3600     # rebuild the catalog once it is older than this

ua       <- "R script (hcdp@hawaii.edu)"
end_time <- Sys.time()

num_vars <- c(
  "temperature", "dewpoint", "relativeHumidity",
  "windDirection", "windSpeed", "windGust",
  "barometricPressure", "seaLevelPressure", "visibility",
  "maxTemperatureLast24Hours", "minTemperatureLast24Hours",
  "precipitationLastHour", "precipitationLast3Hours", "precipitationLast6Hours",
  "windChill", "heatIndex"
)

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
catalog_csv <- file.path(catalog_dir,
                         sprintf("%s_api_stations.csv", tolower(state)))

catalog_age <- function(path) {
  if (!file.exists(path)) return(Inf)
  file_age <- as.numeric(Sys.time() - file.mtime(path), units = "secs")
  ts <- suppressWarnings(parse_utc(read.csv(path)$latest_obs_api))
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
  else if (grepl("^T[A-Z][0-9]{3}$", id)) "raws_fire"
  else if (grepl("^P[0-9]{2}$", id))     "hads_coastal"
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
      api_ts   = parse_utc(latest_obs_api)
    ) |>
    filter(!is.na(group), !is.na(api_ts),
           api_ts >= end_time - alive_window)
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

# --- 2b. Date range: each live station's newest observation in the database
say("Looking up the newest observation of ", nrow(targets),
    " stations in the HCDP database (", api_url, ")...")
targets <- targets |>
  mutate(
    data_ts     = parse_utc(hcdp_latest_obs("nws_api", station_id)),
    fetch_start = pmin(data_ts, end_time - min_fetch),
    fetch_start = if_else(is.na(fetch_start), end_time - max_fetch, fetch_start),
    fetch_start = pmax(fetch_start, end_time - max_fetch)
  )
say(sum(!is.na(targets$data_ts)), " of ", nrow(targets),
    " stations already have data in the database")

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
# normalize the API's "+00:00" timestamps to UTC ISO 8601 text ending in "Z"
obs_long <- obs_long |>
  mutate(datetime = iso_utc(parse_utc(datetime))) |>
  distinct(station_id, datetime, variable, .keep_all = TRUE) |>
  arrange(station_id, datetime, variable)

sum_by_prov <- obs_long |>
  group_by(provider) |>
  summarise(stations = n_distinct(station_id), rows = n())
say(paste(capture.output(print(as.data.frame(sum_by_prov))), collapse = "\n"))
say(sprintf("TOTAL: %d rows, %d stations reporting (of %d targeted)",
                nrow(obs_long), n_distinct(obs_long$station_id), nrow(targets)))

# --- 5. Write to the HCDP database -----------------------------------------
# Metadata first, so stations and variables exist before their observations.
# Station metadata is upserted every run, as in the MADIS workflow, so name,
# provider, location and skn follow the NWS API and the master station list.
# Variable metadata is insert-only (overwrite = FALSE): new variables are
# added, existing rows left as they are.
# data_provider is NOT NULL in the database, and a few stations (buoys among
# them) list no provider on the NWS API, so those are sent as "unknown"; one
# null would reject the whole batch. skn may be null.
station_rows <- targets |>
  filter(station_id %in% obs_long$station_id) |>
  left_join(skn_lookup, by = "station_id") |>
  transmute(station_id, station_name = name,
            data_provider = coalesce(provider, "unknown"),
            skn, lat = latitude, lng = longitude)
amb <- intersect(station_rows$station_id, skn_dupes)
if (length(amb))
  say("Ambiguous NWS.id entries in master table this run (treated as unmatched): ",
      paste(amb, collapse = ", "))
say(sum(!is.na(station_rows$skn)), " of ", nrow(station_rows),
    " reporting stations matched to an SKN")
var_rows <- obs_long |>
  filter(!is.na(unit)) |>
  count(variable, unit) |>
  group_by(variable) |>
  slice_max(n, n = 1, with_ties = FALSE) |>
  ungroup() |>
  select(variable, unit)
# Observations upsert on station_id + timestamp + variable, so a re-fetched
# value replaces what the database had. Rows are sorted by station and time,
# so a run that dies partway leaves each station's newest stored timestamp at
# the point it reached, and the next run re-fetches from there.
data_rows <- obs_long |>
  select(station_id, timestamp = datetime, variable, value)

say("Writing to the HCDP database (", api_url, ")...")
n_sta <- hcdp_write("nws_api", "stationMetadata", station_rows)
n_var <- hcdp_write("nws_api", "variableMetadata", var_rows, overwrite = FALSE)
n_obs <- hcdp_write("nws_api", "data", data_rows)
say(sprintf("Database: %.0f observation rows written; %.0f station rows upserted, %.0f new variables",
            n_obs, n_sta, n_var))

# --- 6. Refresh the catalog so latest_obs_api is current -------------------
invisible(get_station_catalog("HI", cores = n_cores, refresh = TRUE))
