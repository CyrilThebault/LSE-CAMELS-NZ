#!/usr/bin/env Rscript

# Check that all packages required by the workflow are available before running
# the more computationally expensive preparation and emulator steps.
pkgs <- c("ncdf4", "lhs", "ranger", "xgboost", "Matrix", "GA", "parallel")

status <- vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)

print(data.frame(package = pkgs, available = status, row.names = NULL))

if (!all(status)) {
  stop("Missing package(s): ", paste(pkgs[!status], collapse = ", "))
}

message("All required R packages are available.")