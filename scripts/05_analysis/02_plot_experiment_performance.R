# ==============================================================================
# Arguments
# ==============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 2L) {
  stop("Usage: Rscript 02_plot_experiment_performance.R <experiment_root> <dirMain>")
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
  "fold", "step", "ID", "emulator", "eNKGE", "KGEc", "NKGEc", "KGEe", "rank"
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

final_step <- max(plot_data$step, na.rm = TRUE)

final_data <- plot_data[plot_data$step == final_step, , drop = FALSE]

if (!nrow(final_data)) {
  stop("No finite KGEe values available for plotting.")
}


# ==============================================================================
# Output
# ==============================================================================

plot_dir <- ensure_dir(file.path(dirMain, "plots", experiment$timestep, basename(exp_root)))

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

p1 <- ggplot(final_data, aes(x = emulator, y = KGEe, colour = emulator)) +
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
    x <- sort(final_data$KGEe[final_data$emulator == ml])
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

if (length(unique(final_data$fold)) > 1L) {

  p3 <- ggplot(final_data, aes(x = emulator, y = KGEe, colour = emulator)) +
    geom_boxplot(width = 0.55, outlier.shape = NA) +
    geom_jitter(width = 0.12, size = 0.9, alpha = 0.40) +
    facet_wrap(~ fold, nrow = 1) +
    scale_colour_manual(values = emulator_colours) +
    kge_reference_y() +
    labs(x = NULL, y = "Evaluation KGE") +
    theme_lse() +
    theme(legend.position = "none")

  save_figure(p3, "03_kgee_by_fold", width = 12, height = 4.5)

} else {

  message("Single split detected; skipping 03_kgee_by_fold.")

}


# ==============================================================================
# Basin-wise KGE
# ==============================================================================

basin_median <- tapply(
  final_data$KGEe,
  as.character(final_data$ID),
  median,
  na.rm = TRUE
)

basin_order <- names(sort(basin_median))

final_data$basin_order <- match(
  as.character(final_data$ID),
  basin_order
)

p4 <- ggplot(final_data, aes(x = basin_order, y = KGEe, colour = emulator)) +
  geom_point(position = position_dodge(width = 0.55), size = 1, alpha = 0.65) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_y() +
  scale_x_continuous(breaks = NULL) +
  labs(
    x = "Basins ordered by median KGE across emulators",
    y = "Evaluation KGE"
  ) +
  theme_lse()

save_figure(p4, "04_basinwise_kgee", width = 12, height = 5)

# ==============================================================================
# KGE evolution across refinement steps
# ==============================================================================

step_summary <- aggregate(
  KGEe ~ step + emulator,
  data = plot_data,
  FUN = median
)

step_summary$emulator <- factor(
  step_summary$emulator,
  levels = emulator_order
)

p5 <- ggplot(step_summary, aes(x = step, y = KGEe, colour = emulator, group = emulator)) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2) +
  scale_colour_manual(values = emulator_colours) +
  kge_reference_y() +
  scale_x_continuous(breaks = sort(unique(step_summary$step))) +
  labs(x = "Refinement step", y = "Median evaluation KGE") +
  theme_lse()

save_figure(p5, "05_kgee_by_refinement_step")

# ==============================================================================
# Spatial distribution of final-step KGE
# ==============================================================================

spatial <- load_nz_spatial_data(
  dirMain
)

map_data <- join_station_results(
  spatial$stations,
  final_data
)

if (!nrow(map_data)) {
  stop(
    "No station IDs matched the experiment results."
  )
}

map_data$emulator <- factor(
  map_data$emulator,
  levels = emulator_order
)

p6 <- ggplot() +
  geom_sf(
    data = spatial$nz,
    fill = "grey95",
    colour = "grey55",
    linewidth = 0.25
  ) +
  geom_sf(
    data = map_data,
    aes(fill = KGEe),
    shape = 21,
    colour = "black",
    stroke = 0.25,
    size = 1.8,
    alpha = 0.9
  ) +
  scale_fill_gradientn(
    colours = viridisLite::viridis(256),
    limits = c(-0.41, 1),
    oob = scales::squish,
    breaks = c(-0.41, -0.2, 0, 0.2, 0.4, 0.6, 0.8, 1),
    labels = c("< -0.41", "-0.2", "0", "0.2", "0.4", "0.6", "0.8", "1"),
    name = "Evaluation KGE"
  )+
  facet_wrap(
    ~ emulator,
    nrow = 1
  ) +
  coord_sf(
    datum = NA
  ) +
  labs(
    x = NULL,
    y = NULL
  ) +
  theme_lse() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid = element_blank(),
    legend.position = "right",
    legend.title = element_text()
  )

save_figure(
  p6,
  "06_kgee_map",
  width = 11,
  height = 5.5
)

# ==============================================================================
# Performance summary
# ==============================================================================

summary_rows <- lapply(emulator_order, function(ml) {

  x <- final_data$KGEe[final_data$emulator == ml]

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
  file.path(plot_dir, "performance_summary.csv"),
  row.names = FALSE
)



summary_by_step <- do.call(
  rbind,
  lapply(sort(unique(plot_data$step)), function(step) {
    do.call(
      rbind,
      lapply(emulator_order, function(ml) {

        x <- plot_data$KGEe[
          plot_data$step == step &
            plot_data$emulator == ml
        ]

        if (!length(x)) {
          return(NULL)
        }

        data.frame(
          step = step,
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
    )
  })
)

write.csv(
  summary_by_step,
  file.path(plot_dir, "performance_by_step.csv"),
  row.names = FALSE
)

# ==============================================================================
# Final report
# ==============================================================================

cat("\nSaved plots and summary to:\n")
cat("  ", plot_dir, "\n", sep = "")
print(performance_summary)