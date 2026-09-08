# ==============================================================================
# Arguments
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2L) {
  stop("Usage: Rscript 02_plot_kfold_performance.R <experiment_root> <dirMain>")
}

exp_root <- normalizePath(args[1], mustWork = TRUE)
dirMain <- normalizePath(args[2], mustWork = TRUE)


# ==============================================================================
# Functions and configuration
# ==============================================================================

source(file.path(dirMain, "scripts/functions/common.R"))
source(file.path(dirMain, "scripts/functions/plotting.R"))

experiment <- load_workflow_config(dirMain)

library(ggplot2)


# ==============================================================================
# Results
# ==============================================================================

file_results <- file.path(exp_root, "results_summary.csv")

if (!file.exists(file_results)) {
  stop("Missing results summary: ", file_results)
}

results <- read.csv(file_results, stringsAsFactors = FALSE)

required_columns <- c(
  "fold", "ID", "emulator", "eNKGE", "KGEc", "NKGEc", "KGEe", "rank"
)

missing_columns <- setdiff(required_columns, names(results))

if (length(missing_columns)) {
  stop("Missing required column(s): ", paste(missing_columns, collapse = ", "))
}

if (!nrow(results)) {
  stop("results_summary.csv contains no results.")
}


# ==============================================================================
# Plotting factors
# ==============================================================================

emulator_order <- experiment$emulators[
  experiment$emulators %in% unique(results$emulator)
]

unexpected_emulators <- setdiff(unique(results$emulator), emulator_order)

if (length(unexpected_emulators)) {
  emulator_order <- c(emulator_order, sort(unexpected_emulators))
}

results$emulator <- factor(results$emulator, levels = emulator_order)
results$fold <- factor(results$fold, levels = sort(unique(results$fold)))

plot_data <- results[is.finite(results$KGEe), , drop = FALSE]

if (!nrow(plot_data)) {
  stop("No finite KGEe values available for plotting.")
}


# ==============================================================================
# Output
# ==============================================================================

plot_dir <- ensure_dir(file.path(dirMain, "plots", basename(exp_root)))

save_figure <- function(plot, filename, width = 7, height = 5) {
  
  # Vector output, available on headless HPC systems.
  ggsave(
    file.path(plot_dir, paste0(filename, ".pdf")),
    plot,
    width = width,
    height = height,
    device = grDevices::pdf
  )
  
  # Raster output when supported by the local R installation.
  if (capabilities("png")) {
    
    ggsave(
      file.path(plot_dir, paste0(filename, ".png")),
      plot,
      width = width,
      height = height,
      dpi = 300,
      device = grDevices::png
    )
    
  } else {
    
    message(
      "PNG device unavailable; skipping ",
      filename,
      ".png"
    )
  }
}


# ==============================================================================
# KGE distribution
# ==============================================================================

p1 <- ggplot(plot_data, aes(x = emulator, y = KGEe, colour = emulator)) +
  geom_boxplot(width = 0.55, outlier.shape = NA) +
  geom_jitter(width = 0.12, size = 1.2, alpha = 0.45) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_y() +
  labs(x = NULL, y = "Evaluation KGE") +
  theme_lse() +
  theme(legend.position = "none")

save_figure(p1, "01_kgee_distribution")


# ==============================================================================
# KGE ECDF
# ==============================================================================

ecdf_data <- do.call(rbind,
  lapply(emulator_order, function(ml) {
    x <- sort(plot_data$KGEe[plot_data$emulator == ml])
    data.frame(emulator = ml, KGEe = x, probability = seq_along(x) / length(x))
  })
)

ecdf_data$emulator <- factor(ecdf_data$emulator, levels = emulator_order)

p2 <- ggplot(ecdf_data, aes(x = KGEe, y = probability, colour = emulator)) +
  geom_step(linewidth = 0.8) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_x() +
  labs(x = "Evaluation KGE", y = "Empirical cumulative probability") +
  theme_lse()

save_figure(p2, "02_kgee_ecdf")


# ==============================================================================
# KGE by fold
# ==============================================================================

p3 <- ggplot(plot_data, aes(x = emulator, y = KGEe, colour = emulator)) +
  geom_boxplot(width = 0.55, outlier.shape = NA) +
  geom_jitter(width = 0.12, size = 0.9, alpha = 0.40) +
  facet_wrap(~ fold, nrow = 1) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_y() +
  labs(x = NULL, y = "Evaluation KGE") +
  theme_lse() +
  theme(legend.position = "none")

save_figure(p3, "03_kgee_by_fold", width = 12, height = 4.5)


# ==============================================================================
# Basin-wise KGE
# ==============================================================================

basin_median <- tapply(
  plot_data$KGEe,
  as.character(plot_data$ID),
  median,
  na.rm = TRUE
)

basin_order <- names(sort(basin_median))

plot_data$basin_order <- match(
  as.character(plot_data$ID),
  basin_order
)

p4 <- ggplot(plot_data, aes(x = basin_order, y = KGEe, colour = emulator)) +
  geom_point(position = position_dodge(width = 0.55), size = 1, alpha = 0.65) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_y() +
  scale_x_continuous(breaks = NULL) +
  labs(
    x = "Held-out basins ordered by median KGE across emulators",
    y = "Evaluation KGE"
  ) +
  theme_lse()

save_figure(p4, "04_basinwise_kgee", width = 12, height = 5)


# ==============================================================================
# Performance summary
# ==============================================================================

summary_rows <- lapply(emulator_order, function(ml) {
  
  x <- plot_data$KGEe[plot_data$emulator == ml]
  
  data.frame(
    emulator = ml,
    n_basins = length(x),
    mean_KGEe = mean(x),
    median_KGEe = median(x),
    sd_KGEe = sd(x),
    q05_KGEe = unname(quantile(x, 0.05)),
    q25_KGEe = unname(quantile(x, 0.25)),
    q75_KGEe = unname(quantile(x, 0.75)),
    q95_KGEe = unname(quantile(x, 0.95)),
    pct_KGEe_gt_0 = mean(x > 0) * 100,
    pct_KGEe_gt_0_5 = mean(x > 0.5) * 100,
    stringsAsFactors = FALSE
  )
})

performance_summary <- do.call(rbind, summary_rows)

write.csv(
  performance_summary,
  file.path(plot_dir, "kfold_performance_summary.csv"),
  row.names = FALSE
)


# ==============================================================================
# Final report
# ==============================================================================

cat("\nSaved plots and summary to:\n")
cat("  ", plot_dir, "\n", sep = "")
print(performance_summary)