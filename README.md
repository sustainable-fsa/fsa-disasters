
<!-- README.md is generated from README.Rmd. Please edit that file -->

[![Static
Badge](https://img.shields.io/badge/Repo-sustainable--fsa%2Ffsa--disasters-magenta?style=flat)](https://github.com/sustainable-fsa/fsa-disasters/)
![Last
Update](https://img.shields.io/github/last-commit/sustainable-fsa/fsa-disasters?style=flat)
![Repo
Size](https://img.shields.io/github/repo-size/sustainable-fsa/fsa-disasters?style=flat)

This repository is an archive of US Secretary of Agriculture disaster
designations (2012–present) and Presidential Major Disaster declarations
(2017–present). County-level disaster data are acquired weekly from the
<a href="https://www.fsa.usda.gov/resources/disaster-assistance-program/disaster-designation-information" target="_blank">USDA
Disaster Designation portal</a>. The raw data are archived in the
<a href="https://data.sustainable-fsa.com/fsa-disasters/" target="_blank">`data-raw`
directory</a>.

The [`fsa-disasters.R`](fsa-disasters.R) script handles all data
download and processing. The script begins by downloading all USDA
disaster designation spreadsheets from the official site, fixing broken
links and organizing them by year. It then reads these files and
combines them into one dataset, standardizing column names and formats
so the information is consistent across years. Dates are converted to
proper formats, and designation codes are normalized. The data is
cleaned to remove errors and reorganized so each disaster type and
affected county is clearly represented. Finally, the consolidated
dataset is saved in both CSV and Parquet formats for easy analysis, and
in a browser-optimized JSON mirror committed to this repository.

------------------------------------------------------------------------

## About USDA Secretarial Disaster Designations

USDA Secretarial Disaster Designations identify counties impacted by
natural disasters such as drought, flooding, or wildfire. These
designations enable producers in affected areas to access emergency
loans and other assistance programs through the Farm Service Agency
(FSA).

Designations are based on:

- **Production losses** (generally 30% or more)
- **Physical losses** (e.g., infrastructure damage)
- Recommendations from state and local officials

## About Presidential Major Disaster Declarations

Presidential Major Disaster Declarations are issued under the **Stafford
Act** and authorize federal assistance for communities affected by
severe disasters. These declarations:

- Provide access to FEMA programs for individuals and public
  infrastructure
- Often complement USDA disaster programs for agricultural producers
- Are based on severity, scope, and state requests for federal aid

FEMA maintains a database of Major Disaster declarations as part of the
<a href="https://www.fema.gov/about/reports-and-data/openfema" target="_blank">OpenFEMA
data portal</a>. Additionally, the USDA Farm Service Agency also
provides access to Presidential Major Disaster declarations.

------------------------------------------------------------------------

## 🗂 Directory Structure

- [`fsa-disasters.R`](fsa-disasters.R): R script that updates
  secretarial and presidential disaster data based on files posted by
  the FSA.
- [`fsa-disasters.parquet`](fsa-disasters.parquet): Consolidated
  disaster data in a single parquet file.
- [`fsa-disasters.csv`](fsa-disasters.csv): Consolidated disaster data
  in a single comma-separated values file.
- [`fsa-disasters.json`](https://data.sustainable-fsa.com/fsa-disasters/fsa-disasters.json):
  The same records restructured for browsers — dictionary-coded,
  declaration-normalized JSON (see below). Unlike the CSV and Parquet,
  committed to git as well as mirrored to S3.
- [data-raw/](data-raw/): Directory containing raw disaster data files
  as posted by the FSA.
- [`README.Rmd`](README.Rmd): This README file, providing an overview
  and usage instructions.

------------------------------------------------------------------------

## 📦 `fsa-disasters.json`

The same records as the CSV and Parquet — derived from the identical
table in the same run — restructured for direct use in a browser. It is
not an archive-of-record format; for analysis, use the CSV or Parquet.
It differs in structure, not content:

- **Column-oriented**: one array per field with one entry per record,
  rather than one object per record.
- **Declaration-normalized**: the flat table repeats each declaration’s
  year, number, description, and three dates once per county that
  declaration names. Here the 3,907 distinct declaration amendments are
  a table of their own, and the 184,815 county rows carry an index into
  it. With the column orientation, that takes the file to about 4 MB raw
  and roughly 390 KB gzipped over the wire.
- **Dictionary-coded strings**: disaster years, declaration types and
  numbers, disaster descriptions and types, FIPS codes, and county and
  state names each appear once in a lookup array; the record arrays hold
  integer indices into them.
- **Compact dates**: each date is an integer count of days since
  1970-01-01 rather than an ISO string, and is `null` wherever FSA
  reports no date — most often an end date, absent on about 104,000
  rows.
- **Values verbatim, irregularities included**: the payload mirrors the
  archive rather than cleaning it. `Disaster Year` is `"0"` on 84 rows
  and `"2011, 2012"` on 10, and 270 approval dates are 1899-12-30 — a
  spreadsheet zero, which encodes here as the negative day count
  `-25569`.

The payload is self-describing via its `schema` field
(`fsa-disasters/1`), a frozen contract with its consumers: fields may be
added, but existing ones are never renamed or reordered without bumping
the schema.

------------------------------------------------------------------------

## 📍 Quick Start: Visualize the 2025 Secretarial Disaster Designations for Drought in R

This snippet shows how to load a the parquet file from the archive and
create a thematic map using `sf` and `ggplot2`.

``` r
# Load required libraries
library(arrow)
library(sf)
library(ggplot2) # For plotting
library(tigris)  # For state boundaries
library(rmapshaper) # For innerlines function

# Read the full designations archive
designations <-
  "https://data.sustainable-fsa.com/fsa-disasters/fsa-disasters.parquet" |>
  arrow::read_parquet()

# The most recent designation approval in the archive
latest_approval <-
  max(designations$`Approval date`, na.rm = TRUE)

# Get the 2026 Secretarial disasters for drought
disasters <-
  designations |>
  dplyr::filter(`Designation/Declaration Type` == "Secretarial",
                stringr::str_detect(`Disaster Type`, "DROUGHT"),
                `Disaster Year` == 2026) |>
  dplyr::arrange(`Designation Code`) %>%
  dplyr::distinct(FIPS, .keep_all = TRUE)

## Load the US Census county data
counties <- 
  tigris::counties(cb = TRUE,
                   year = 2020,
                   resolution = "5m",
                   progress_bar = FALSE) |>
  dplyr::filter(!(STATEFP %in% c("60", "66", "69", "78"))) |>
  # transform to WGS 84
  sf::st_transform("EPSG:4326") |>
  sf::st_cast("POLYGON", warn = FALSE, do_split = TRUE) |>
  tigris::shift_geometry() |>
  dplyr::group_by(STATEFP, COUNTYFP) |>
  dplyr::summarise(.groups = "drop") |>
  sf::st_cast("MULTIPOLYGON") |>
  dplyr::mutate(FIPS = paste0(STATEFP, COUNTYFP))

disasters_counties <-
  disasters |>
  dplyr::left_join(counties) |>
  sf::st_as_sf()

# Plot the map
ggplot(counties) +
  geom_sf(data = sf::st_union(counties),
          fill = "grey80",
          color = NA) +
  geom_sf(data = disasters_counties,
          aes(fill = `Designation Code`), 
          color = NA) +
  geom_sf(data = rmapshaper::ms_innerlines(counties),
          fill = NA,
          color = "white",
          linewidth = 0.1) +
  geom_sf(data = counties |>
            dplyr::group_by(STATEFP) |>
            dplyr::summarise() |>
            rmapshaper::ms_innerlines(),
          fill = NA,
          color = "white",
          linewidth = 0.2) +
  scale_fill_manual(
    values = c(
      "Primary" = "#DC0005",
      "Contiguous" = "#FD9A09"
    ),
    na.value = NA,
    drop = FALSE,
    na.translate = FALSE,
    name = "Designation Code") +
  labs(title = "2026 USDA Secretarial Disaster Designations for Drought",
       subtitle = paste("Designations approved through",
                        format(latest_approval, "%B %d, %Y"))) +
  theme_void()
```

<img src="./example-1.png" alt="" style="display: block; margin: auto;" />

Latest designation approval date: **June 08, 2026**

------------------------------------------------------------------------

## 📝 Citation

If you use this data in published work, please cite:

> USDA Farm Service Agency. *Secretarial Disaster Designations
> (2012–present) and Presidential Major Disaster Declarations
> (2017–present)*. Curated and archived by R. Kyle Bocinsky, Montana
> Climate Office, University of Montana. Sustainable FSA project.
> Accessed YYYY-MM-DD. <https://sustainable-fsa.com/fsa-disasters/>

Machine-readable metadata are in [`CITATION.cff`](CITATION.cff);
GitHub’s **Cite this repository** button (top right of the repo page)
renders it as APA or BibTeX.

**Acknowledgment**: This work is part of the [*Enhancing Sustainable
Disaster Relief in FSA
Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)
project, supported by the USDA Office of the Chief Economist, Office of
Energy and Environmental Policy, and the USDA Climate Hubs.

## 📄 License

- **Raw data**: Public Domain (17 USC § 105)
- **Processed data & scripts**: © R. Kyle Bocinsky, released under
  [CC0](https://creativecommons.org/publicdomain/zero/1.0/) and [MIT
  License](./LICENSE) as applicable

------------------------------------------------------------------------

## ⚠️ Disclaimer

This dataset is archived for research and educational use only.

------------------------------------------------------------------------

## 👏 Acknowledgment

This project is part of:

**[*Enhancing Sustainable Disaster Relief in FSA
Programs*](https://www.ars.usda.gov/research/project/?accnNo=444612)**\
Supported by USDA OCE/OEEP and USDA Climate Hubs\
Prepared by the [Montana Climate Office](https://climate.umt.edu)

------------------------------------------------------------------------

## 📬 Contact

**R. Kyle Bocinsky**\
Director of Climate Extension\
Montana Climate Office\
📧 <kyle.bocinsky@umontana.edu>\
🌐 <https://climate.umt.edu>
