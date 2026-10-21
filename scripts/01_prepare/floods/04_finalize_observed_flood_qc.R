#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly=TRUE)

force <- length(args) > 0L && tail(args, 1L) == "--force"
if (force) args <- head(args, -1L)

if (length(args) > 1L) {
  stop("Usage: Rscript 04_finalize_observed_flood_qc.R [dirMain] [--force]")
}
dirMain <- if (length(args)) normalizePath(args[1], mustWork=TRUE) else
  normalizePath(".", mustWork=TRUE)

fileCatalogue <- file.path(dirMain, "data", "flood", "observed_flood_catalogue.csv")
fileQC <- file.path(dirMain, "data", "flood", "qc", "observed_flood_qc.csv")
fileDecisions <- file.path(dirMain, "data", "flood", "qc",
                           "observed_flood_qc_decisions.csv")
fileOut <- file.path(dirMain, "data", "flood", "qc",
                    "observed_flood_catalogue_reviewed.csv")

if (file.exists(fileOut) && !force) {
  stop(
    "Reviewed flood catalogue already exists: ", fileOut,
    "\nUse --force to explicitly allow replacement."
  )
}

clean_chr <- function(x) {
  x <- trimws(as.character(x))
  x[is.na(x)] <- ""
  x
}

require_cols <- function(x, cols, label) {
  missing <- setdiff(cols, names(x))
  if (length(missing)) {
    stop(label, " is missing column(s): ", paste(missing, collapse=", "))
  }
}

stopifnot(file.exists(fileCatalogue), file.exists(fileQC), file.exists(fileDecisions))

catalogue <- read.csv(fileCatalogue, stringsAsFactors=FALSE)
qc <- read.csv(fileQC, stringsAsFactors=FALSE)
dec <- read.csv(fileDecisions, stringsAsFactors=FALSE)

require_cols(catalogue, "event_id", "Catalogue")
require_cols(qc, c("event_id", "review_required", "review_reasons"), "QC file")
require_cols(dec, c("event_id", "decision", "reason", "comment"),
             "Decision file")

catalogue$event_id <- clean_chr(catalogue$event_id)
qc$event_id <- clean_chr(qc$event_id)

if (!identical(catalogue$event_id, qc$event_id)) {
  stop("Catalogue and QC event IDs are not identical and in the same order.")
}

review_required <- as.logical(qc$review_required)
if (anyNA(review_required)) stop("Invalid review_required value in QC file.")

for (nm in names(dec)) dec[[nm]] <- clean_chr(dec[[nm]])
dec <- dec[nzchar(dec$event_id), , drop=FALSE]
dec$decision <- tolower(dec$decision)

if (anyDuplicated(dec$event_id)) {
  ids <- unique(dec$event_id[duplicated(dec$event_id)])
  stop("Duplicate decision(s) for event_id: ", paste(ids, collapse=", "))
}

completed <- nzchar(dec$decision)

invalid <- completed & !(dec$decision %in% c("keep", "exclude"))
if (any(invalid)) {
  stop("Invalid decision value(s): ",
       paste(unique(dec$decision[invalid]), collapse=", "),
       ". Allowed values are keep and exclude.")
}

unknown <- !(dec$event_id %in% catalogue$event_id)
if (any(unknown)) {
  stop("Decision file contains unknown event_id(s): ",
       paste(dec$event_id[unknown], collapse=", "))
}


exclude_without_reason <- completed &
  dec$decision == "exclude" & !nzchar(dec$reason)
if (any(exclude_without_reason)) {
  stop("Exclude decisions require a reason: ",
       paste(dec$event_id[exclude_without_reason], collapse=", "))
}

if (any(completed)) {
  pos_dec <- match(dec$event_id, catalogue$event_id)
  keep_unflagged <- completed &
    dec$decision == "keep" & !review_required[pos_dec]

  if (any(keep_unflagged)) {
    stop("A keep decision is only valid for review_required events: ",
         paste(dec$event_id[keep_unflagged], collapse=", "))
  }
}

n <- nrow(catalogue)
status <- ifelse(review_required, "review_pending", "auto_pass")
decision <- reason <- comment <- rep("", n)

if (any(completed)) {
  d <- dec[completed, , drop=FALSE]
  pos <- match(d$event_id, catalogue$event_id)

  decision[pos] <- d$decision
  reason[pos] <- d$reason
  comment[pos] <- d$comment

  status[pos] <- ifelse(
    d$decision == "keep",
    "review_keep",
    ifelse(review_required[pos], "review_exclude", "manual_exclude")
  )
}

pending <- which(status == "review_pending")

cat("\n===== OBSERVED FLOOD QC FINALIZATION =====\n\n")
cat("Catalogue events :", n, "\n")
cat("Review required  :", sum(review_required), "\n")
cat("Decision rows    :", nrow(dec), "\n")
cat("Completed        :", sum(completed), "\n")
cat("Pending reviews  :", length(pending), "\n")

if (length(pending)) {
  cat("\nFirst pending event IDs:\n")
  print(head(catalogue$event_id[pending], 20L), quote=FALSE)
  stop("QC review is incomplete; no finalized catalogue was written.")
}

out <- catalogue
out$review_required <- review_required
out$review_reasons <- clean_chr(qc$review_reasons)
out$qc_status <- status
out$analysis_eligible <- status %in% c("auto_pass", "review_keep")
out$qc_decision <- decision
out$qc_decision_reason <- reason
out$qc_comment <- comment

dir.create(dirname(fileOut), recursive=TRUE, showWarnings=FALSE)
write.csv(out, fileOut, row.names=FALSE)

cat("\nQC status:\n")
print(table(out$qc_status, useNA="ifany"))

cat("\nAnalysis eligible :", sum(out$analysis_eligible), "\n")
cat("Excluded          :", sum(!out$analysis_eligible), "\n")
cat("\nFinal catalogue   :", fileOut, "\n")
cat("\nOBSERVED FLOOD QC FINALIZATION: OK\n")
