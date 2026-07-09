# update.packages(repos = "https://cran.rstudio.com/",
#                 ask = FALSE)

# Packages are provided by mt-climate-office/actions/setup-geospatial in CI.
# For a bare local R installation, install manually:
# install.packages("pak", repos = "https://mac.r-project.org")
# pak::pak(
#   c(
#     "arrow",
#     "sf",
#     "curl",
#     "tidyverse",
#     "tigris",
#     "rmapshaper",
#     "furrr",
#     "future.mirai",
#     "httr2"
#   )
# )

library(magrittr)
library(tidyverse)
library(furrr)
library(future.mirai)
library(arrow)

source("R/s3-archive.R")
s3_preflight()

s3_bucket <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix <- Sys.getenv("S3_PREFIX", unset = "fsa-disasters")

update_disasters <- TRUE

if(update_disasters){
  raw_path <- "data-raw"
  
  dir.create(raw_path,
             recursive = TRUE,
             showWarnings = FALSE)
  
  raw_files <-
    xml2::read_html("https://www.fsa.usda.gov/resources/disaster-assistance-program/disaster-designation-information") %>%
    xml2::xml_find_all(".//a") %>%
    { .[grepl("xls|metadata-cy", xml2::xml_attr(., "href"))] } %>%
    {
      tibble(
        year = xml2::xml_text(.),
        request = xml2::xml_attr(., "href")
      ) 
    } %>%
    mutate(year = year %>%
             stringr::str_squish() %>%
             as.integer(),
           request = xml2::url_absolute(request, "https://www.fsa.usda.gov")
    ) %>%
    dplyr::rowwise() %>%
    dplyr::mutate(
      request = ifelse(stringr::str_detect(request, "xls"),
                       request,
                       xml2::read_html(request) %>%
                         xml2::xml_find_all(".//a") %>%
                         xml2::xml_attr("href") %>%
                         stringr::str_subset("xls")
                       
      ),
      type = ifelse(stringr::str_detect(request, "pres|PRES"), "Presidential", "Secretarial"),
      ## Correct wrong file path on website
      request = ifelse(year == 2021L & type == "Secretarial", 
                       "https://www.fsa.usda.gov/sites/default/files/documents/METADATA_CY2021_SEC_YTD.xlsx",
                       request),  
      outfile = 
        file.path(raw_path, 
                  basename(request)) %>%
        stringr::str_replace_all("%20", " ")
    ) %>%
    dplyr::ungroup()
  
  ## Download the raw data
  # raw_files %$%
  #   curl::multi_download(
  #     urls = request,
  #     destfiles = outfile,
  #     resume = TRUE
  #   )
  download_results <- 
    raw_files %$%
    purrr::map2_dfr(request, outfile, 
                    .f = 
                      ~curl::multi_download(url = .x,
                                            destfile = .y,
                                            progress = FALSE,
                                            resume = TRUE
                      ))
  
  if(any(!is.na(download_results$error))){
    stop("FILE DOWNLOAD ERRORS")
  }
  
  plan(mirai_multisession)
  
  disasters <-
    raw_files %>%
    dplyr::ungroup() %>%
    dplyr::mutate(
      data = furrr::future_map(outfile,
                               readxl::read_excel, 
                               col_types = "text")) %>%
    tidyr::unnest(data) %>%
    ## mutates to fix column names
    dplyr::mutate(
      `Designation Code` = 
        case_when(
          !is.na(`Designation Code`) ~ `Designation Code`,
          !is.na(Desig_Cd) ~ `Desig_Cd`,
          !is.na(`Designation Code\n(1 = primary, 2 = contiguous)`) ~ 
            `Designation Code\n(1 = primary, 2 = contiguous)`,
          !is.na(`Designation Code\r\n(1 = primary, 2 = contiguous)`) ~
            `Designation Code\r\n(1 = primary, 2 = contiguous)`),
      `Description of Disaster` =
        case_when(
          !is.na(`Description of Disaster`) ~ `Description of Disaster`,
          !is.na(`Description of disaster`) ~ `Description of disaster`
        ),
      `Designation Number` =
        case_when(
          !is.na(`Designation Number`) ~ `Designation Number`,
          !is.na(`Desig. No.`) ~ `Desig. No.`
        ),
      `Ground Saturation/Standing Water` = 
        case_when(
          !is.na(`Ground Saturation\r\nStanding Water`) ~ `Ground Saturation\r\nStanding Water`,
          !is.na(`Ground Saturation\nStanding Water`) ~ `Ground Saturation\nStanding Water`,
        ),
      `Heat, Excessive heat, High temp. (incl. low humidity)` = 
        case_when(
          !is.na(`Heat, Excessive heat\r\nHigh temp. (incl. low humidity)`) ~ `Heat, Excessive heat\r\nHigh temp. (incl. low humidity)`,
          !is.na(`Heat, Excessive heat\nHigh temp. (incl. low humidity)`) ~ `Heat, Excessive heat\nHigh temp. (incl. low humidity)`
        ),
      `Disaster Year` = 
        case_when(
          !is.na(`Crop Year`) ~ `Crop Year`,
          !is.na(`CROP DISASTER YEAR`) ~ `CROP DISASTER YEAR`,
          !is.na(`CALENDAR DISASTER YEAR`) ~ `CALENDAR DISASTER YEAR`,
          !is.na(`DISASTER YEAR`) ~ `DISASTER YEAR`,
          !is.na(...37) ~ ...37
        ),
      `Designation/Declaration Number` = 
        case_when(
          !is.na(`Designation Number`) ~ `Designation Number`,
          !is.na(`Declaration Number`) ~ `Declaration Number`
        ),
      `Volcano/VOG` = 
        case_when(
          !is.na(Volcano) ~ Volcano,
          !is.na(`Volcano, "VOG"`) ~ `Volcano, "VOG"`
        ),
      `County/Tribal Government` = 
        case_when(
          !is.na(`County/Tribal Government`) ~ `County/Tribal Government`,
          !is.na(County) ~ County
        )
    ) %>%
    dplyr::select(!c(outfile,
                     Desig_Cd,
                     `Designation Code\n(1 = primary, 2 = contiguous)`,
                     `Designation Code\r\n(1 = primary, 2 = contiguous)`,
                     `Description of disaster`,
                     `Ground Saturation\r\nStanding Water`,
                     `Ground Saturation\nStanding Water`,
                     `Heat, Excessive heat\r\nHigh temp. (incl. low humidity)`,
                     `Heat, Excessive heat\nHigh temp. (incl. low humidity)`,
                     `Crop Year`,
                     `CROP DISASTER YEAR`,
                     `CALENDAR DISASTER YEAR`,
                     `DISASTER YEAR`,
                     `Designation Number`,
                     `Declaration Number`,
                     `Desig. No.`,
                     Volcano,
                     `Volcano, "VOG"`,
                     ...37,
                     ...34, 
                     ...35,
                     ...36,
                     County)) %>%
    dplyr::select(`Designation/Declaration Type` = type, year, `Disaster Year`, 
                  `Designation/Declaration Number`, `Amendment Number` = `Amendment No.`,
                  `Designation Code`,
                  `Description of Disaster`,
                  `Approval date`, `Begin Date`, `End Date`,
                  FIPS, `County/Tribal Government`, State, request,
                  dplyr::everything()) %>%
    dplyr::mutate(
      `Approval date` = lubridate::as_date(as.numeric(`Approval date`), origin = "1899-12-30"), 
      `Begin Date` = lubridate::as_date(as.numeric(`Begin Date`), origin = "1899-12-30"),
      `End Date` = lubridate::as_date(as.numeric(`End Date`), origin = "1899-12-30"),
      `Designation Code` = 
        factor(
          `Designation Code`,
          levels = c("1", "2"),
          labels = c("Primary", "Contiguous"),
          ordered = TRUE
        ),
      # Correct clearly erroneous data
      `Begin Date` = 
        case_when(`Begin Date` == "2027-07-09" ~  
                    lubridate::as_date("2024-07-09"),
                  `Begin Date` == "2025-10-15" & 
                    `Designation/Declaration Number` == "S5897" ~  
                    lubridate::as_date("2024-10-15"),
                  .default = `Begin Date`) %>%
        lubridate::as_date()
    ) %>%
    tidyr::pivot_longer(!c(`Designation/Declaration Type`:request),
                        names_to = "Disaster Type") %>%
    dplyr::filter(value == "1") %>%
    dplyr::select(!c(value)) %>%
    dplyr::arrange( 
      `Designation/Declaration Number`, `Amendment Number`,
      FIPS, `Disaster Type`
    )
  
  plan(sequential)
  
  disaster_declarations <-
    disasters %>%
    dplyr::select(`Disaster Year`,
                  `Designation/Declaration Type`, 
                  `Designation/Declaration Number`,
                  `Amendment Number`,
                  `Description of Disaster`,
                  `Disaster Type`,
                  `Approval date`, `Begin Date`, `End Date`) %>%
    dplyr::arrange(
      `Disaster Year`,
      `Designation/Declaration Type`, 
      `Designation/Declaration Number`,
      `Amendment Number`,
      dplyr::desc(`Approval date`),
      dplyr::desc(`Begin Date`),
      dplyr::desc(`End Date`)
    ) %>%
    dplyr::distinct(`Disaster Year`,
                    `Designation/Declaration Type`, 
                    `Designation/Declaration Number`,
                    `Amendment Number`,
                    `Disaster Type`,
                    .keep_all = TRUE) %>%
    tidyr::nest(`Disaster Type` = `Disaster Type`)
  
  disaster_counties <-
    disasters %>%
    dplyr::select(`Disaster Year`,
                  `Designation/Declaration Type`, 
                  `Designation/Declaration Number`,
                  `Amendment Number`,
                  FIPS, `County/Tribal Government`, State,
                  `Designation Code`
    ) %>%
    dplyr::distinct() %>%
    dplyr::arrange(`Disaster Year`,
                   `Designation/Declaration Type`, 
                   `Designation/Declaration Number`,
                   `Amendment Number`,
                   `Designation Code`,
                   FIPS) %>%
    tidyr::nest(
      `County/Tribal Government` = c(FIPS,
                                     `County/Tribal Government`,
                                     State,
                                     `Designation Code`)
    )
  
  disasters <-
    dplyr::full_join(
      disaster_declarations,
      disaster_counties
    ) %>%
    tidyr::unnest(`Disaster Type`) %>%
    tidyr::unnest(`County/Tribal Government`) %>%
    dplyr::arrange(dplyr::desc(`Begin Date`),
                   `Designation/Declaration Number`) %T>%
    readr::write_csv("fsa-disasters.csv") %T>%
    arrow::write_parquet(sink = "fsa-disasters.parquet",
                         version = "latest",
                         compression = "zstd",
                         use_dictionary = TRUE)
  
  
  
}

## Create directory listing infrastructure
generate_tree_flat <- function(
    data_dir = "data-raw", 
    output_file = file.path("manifest.json")) {
  
  all_entries <- 
    fs::dir_ls(data_dir, recurse = TRUE, all = TRUE, type = "file") |>
    stringr::str_subset("(^|/)[.][^/]+", negate = TRUE)
  
  entries <- list()
  
  for (entry in all_entries) {
    rel_path <- fs::path_rel(entry, start = ".")
    info <- fs::file_info(entry)
    is_dir <- fs::is_dir(entry)
    entry_data <- list(
      path = as.character(rel_path),
      size = if (is_dir) "-" else info$size,
      mtime = if (is_dir) "-" else format(info$modification_time, "%Y-%Om-%d %H:%M:%S")
    )
    entries[[length(entries) + 1]] <- entry_data
  }
  
  # Sort by path
  entries <- entries[order(sapply(entries, function(x) x$path))]
  
  jsonlite::write_json(entries, output_file, pretty = TRUE, auto_unbox = TRUE)
  message("✅ Wrote ", length(entries), " entries to ", output_file)
}

# Generate the flat index
generate_tree_flat()

## Publish the archive to S3
s3_push(bucket = s3_bucket,
        prefix = paste0(s3_prefix, "/data-raw"),
        local_dir = "data-raw",
        delete = TRUE)

s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/fsa-disasters.csv"),
       file = "fsa-disasters.csv",
       content_type = "text/csv",
       cache_control = "max-age=3600")

s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/fsa-disasters.parquet"),
       file = "fsa-disasters.parquet",
       content_type = "application/vnd.apache.parquet",
       cache_control = "max-age=3600")

s3_put(bucket = s3_bucket,
       key = paste0(s3_prefix, "/manifest.json"),
       file = "manifest.json",
       content_type = "application/json",
       cache_control = "max-age=3600")

s3_verify(bucket = s3_bucket,
          prefix = paste0(s3_prefix, "/data-raw"),
          local_dir = "data-raw")

s3_write_manifest(bucket = s3_bucket,
                  prefix = s3_prefix)

cf_invalidate(
  paths = c(
    paste0("/", s3_prefix, "/fsa-disasters.csv"),
    paste0("/", s3_prefix, "/fsa-disasters.parquet"),
    paste0("/", s3_prefix, "/manifest.json"),
    paste0("/", s3_prefix, "/_manifest.txt")
  )
)

# ---- Render the README ----
# Regenerates README.md and the example map from the freshly updated
# archive; the workflow commits these (and only these) back to git.
rmarkdown::render("README.Rmd")
